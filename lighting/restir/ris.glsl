#ifndef ADV_LIGHTING_RESTIR_RIS_GLSL
#define ADV_LIGHTING_RESTIR_RIS_GLSL

// RIS light sampling (the method of the Chromance-VKPT shader pack), used when Direct lighting mode = RIS.
//
// Instead of keeping reservoirs between frames and sharing them between pixels (ReSTIR), every pixel does this
// from scratch each frame:
//   1. collect the lights of the 2 x 2 x 2 chunk sections nearest to the shading point (on every axis the section
//      the point is in and the neighbour on the side it is closer to; lights further away are at least 8 blocks
//      off),
//   2. pick a few candidates uniformly among those lights and a random point on each,
//   3. keep one candidate with probability proportional to its unshadowed contribution (resampled importance
//      sampling),
//   4. the caller traces one shadow ray towards the kept sample.
// Nothing is carried over from earlier frames, so the light cannot lag or ghost behind the camera.
//
// Needs lighting/restir/resampling.glsl (light buffers, target function, shadow ray set-up).

#include "lighting/restir/resampling.glsl"

struct RisSections {
    uint chunkIndex[8];   // index into chunkLights[]
    uint end[8];          // running total of lights up to and including this section
    int count;
    uint total;           // number of lights in all collected sections
};

RisSections risGatherSections(vec3 scenePosition) {
    RisSections sections;
    sections.count = 0;
    sections.total = 0u;
    for (int i = 0; i < 8; ++i) {
        sections.chunkIndex[i] = 0u;
        sections.end[i] = 0u;
    }

    vec3 sectionPosition = (scenePosition + vec3(worldUBO.cameraPos.xyz)) / 16.0;
    ivec3 center = ivec3(floor(sectionPosition));
    vec3 within = sectionPosition - vec3(center);
    ivec3 side = ivec3(step(vec3(0.5), within)) * 2 - 1;
    for (int i = 0; i < 8; ++i) {
        ivec3 sectionCoordinate = center + ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1) * side;
        int resolvedIndex;
        ivec3 chunkOrigin;
        if (!findChunkIndex(sectionCoordinate, worldUBO, resolvedIndex, chunkOrigin)) { continue; }
        ChunkLights chunk = chunkLights[resolvedIndex];
        if (!matchesChunkLights(chunk, chunkOrigin)) { continue; }
        uint lightCount = getChunkLightCount(chunk);
        if (lightCount == 0u) { continue; }
        sections.total += lightCount;
        sections.chunkIndex[sections.count] = uint(resolvedIndex);
        sections.end[sections.count] = sections.total;
        ++sections.count;
    }
    return sections;
}

struct RisLightSample {
    vec3 point;
    vec3 normal;
    vec3 radiance;
    vec3 contribution;      // unshadowed diffuse contribution of the kept sample (before the weight)
    vec3 direction;         // direction from the surface to the kept sample
    float contributionWeight;
};

// Resamples `candidateCount` candidates down to one. On success the unshadowed light reaching the surface is
// sample.contribution * sample.contributionWeight, to be multiplied by the shadow ray's transmittance.
bool risSampleLight(RestirTarget target, RisSections sections, inout uint seed, out RisLightSample result) {
    result.point = vec3(0.0);
    result.normal = vec3(0.0, 1.0, 0.0);
    result.radiance = vec3(0.0);
    result.contribution = vec3(0.0);
    result.direction = vec3(0.0);
    result.contributionWeight = 0.0;
    if (sections.total == 0u || sections.count == 0) { return false; }

    int candidateCount = clamp(int(ADV_RIS_CANDIDATES), 1, 32);
    float totalLights = float(sections.total);
    float weightSum = 0.0;
    float chosenTarget = 0.0;

    for (int i = 0; i < candidateCount; ++i) {
        uint pick = min(uint(clamp(rand(seed), 0.0, ADV_UNIT_OPEN_UPPER_BOUND) * totalLights), sections.total - 1u);
        int k = 0;
        while (k < sections.count - 1 && pick >= sections.end[k]) { ++k; }
        uint first = k == 0 ? 0u : sections.end[k - 1];
        ChunkLights chunk = chunkLights[sections.chunkIndex[k]];
        PackedLight light;
        if (!loadPackedLight(chunk, pick - first, light)) { continue; }

        vec3 point;
        vec3 normal;
        float areaPdf;
        uint sampleParam;
        if (!sampleRestirLightPoint(light, seed, point, normal, areaPdf, sampleParam) || areaPdf <= 1e-8) {
            continue;
        }
        vec3 radiance = packedRestirLightRadiance(light);
        vec3 contribution;
        vec3 direction;
        float targetFunction = evaluateRestirTarget(target, radiance, point, normal, contribution, direction);
        if (!isBrdfFinite(targetFunction) || targetFunction <= 1e-8) { continue; }

        // Source pdf of a candidate = (1 / number of lights) * (1 / light area).
        float weight = targetFunction * totalLights / areaPdf;
        if (!isBrdfFinite(weight) || weight <= 0.0) { continue; }
        weightSum += weight;
        if (rand(seed) * weightSum <= weight) {
            chosenTarget = targetFunction;
            result.point = point;
            result.normal = normal;
            result.radiance = radiance;
            result.contribution = contribution;
            result.direction = direction;
        }
    }
    if (weightSum <= 0.0 || chosenTarget <= 0.0) { return false; }

    // Candidates that came out invalid still count in the denominator (they have zero weight).
    result.contributionWeight = weightSum / (float(candidateCount) * chosenTarget);
    return isBrdfFinite(result.contributionWeight) && result.contributionWeight > 0.0;
}

#endif
