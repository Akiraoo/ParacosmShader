#ifndef ADV_ENVIRONMENT_CLIMATE_GLSL
#define ADV_ENVIRONMENT_CLIMATE_GLSL

// Sunlit: how cold the biome around the camera is (1 = snowy, 0 = warm), for the aurora. Radiance does not pass
// the biome to shaders, so it is estimated:
//  * by day from the vanilla sky colour, which Minecraft derives from the biome temperature (exact);
//  * at night that colour is black, so the last daytime value is kept while the camera stays within ~300 blocks;
//  * otherwise (joined or travelled at night) from how much of the nearby ground seen by the camera is snow.
// The discover pass counts snow samples, compose updates the estimate once per frame and hands it to the next
// frame's sky capture through camera_medium.b.

#ifndef ADV_AURORA_MODE
#    define ADV_AURORA_MODE 1
#endif

#include "environment/sunlit_state.glsl"

#ifdef ADV_CLIMATE_SAMPLE_GROUND
// Called by the primary discover pass for a sparse grid of pixels: count nearby upward-facing terrain and how much
// of it is snow (near-white, unsaturated texture).
void sampleSunlitGroundClimate(HitPayload hit, vec3 rayDirection, uvec2 launchId) {
    if ((launchId.x & 7u) != 3u || (launchId.y & 7u) != 5u) { return; }
    if (worldUBO.skyType != 1u || rayDirection.y > -0.05) { return; }
    if (!isHitValid(hit) || !isChunkGeometryBufferIndex(hit.geometryBufferIndex) || hit.hitT > 64.0) { return; }

    uint i0, i1, i2;
    PositionVertex p0, p1, p2;
    MaterialVertex m0, m1, m2;
    loadTriangle(hit.geometryBufferIndex, hit.primitiveId, i0, i1, i2, p0, p1, p2, m0, m1, m2);
    if (!hasTexture(m0.packedData)) { return; }
    vec3 normal = cross(p1.pos - p0.pos, p2.pos - p0.pos);
    float normalLength = length(normal);
    if (normalLength <= 1e-8 || abs(normal.y) < 0.9 * normalLength) { return; }

    vec2 barycentrics = clamp(hit.barycentrics, vec2(0.0), vec2(1.0));
    vec3 weights = vec3(1.0 - barycentrics.x - barycentrics.y, barycentrics.x, barycentrics.y);
    vec2 uv = weights.x * m0.textureUV + weights.y * m1.textureUV + weights.z * m2.textureUV;
    vec3 albedo = textureLod(textures[nonuniformEXT(m0.textureID)], uv, 2.0).rgb;
    float brightest = max(albedo.r, max(albedo.g, albedo.b));
    float darkest = min(albedo.r, min(albedo.g, albedo.b));
    bool isSnow = darkest > 0.82 && brightest - darkest < 0.10;

    atomicAdd(sunlitGroundSamples, 1u);
    if (isSnow) { atomicAdd(sunlitSnowSamples, 1u); }
}
#endif

#ifdef ADV_CLIMATE_UPDATE
// Called once per frame (one invocation of the compose pass), after updateSunlitState(). Returns the smoothed
// estimate.
float updateSunlitClimate() {
    if (!isSunlitStateValid()) { return 0.0; }
    uint snow = sunlitSnowSamples;
    uint ground = sunlitGroundSamples;
    sunlitSnowSamples = 0u;
    sunlitGroundSamples = 0u;
    uint flags = sunlitStateFlags;
    if (worldUBO.skyType != 1u) { return sunlitClimate; }

    vec2 camera = vec2(worldUBO.cameraPos.xz);
    // Vanilla overworld sky colour: HSV(0.622 - 0.05 f, 0.5 + 0.1 f, 1) with f = temperature / 3, so in full
    // daylight red / blue = 0.5 - 0.1 f. Rain and dusk change it, so only clear daytime frames are used.
    vec3 skyColor = skyUBO.baseColor;
    if (skyUBO.rainGradient < 0.02 && skyColor.b > 0.9 && skyColor.b >= max(skyColor.r, skyColor.g)) {
        float temperature = 30.0 * (0.5 - skyColor.r / skyColor.b);
        sunlitSkyCold = 1.0 - smoothstep(0.05, 0.35, temperature);
        sunlitLatchX = camera.x;
        sunlitLatchZ = camera.y;
        flags |= ADV_SUNLIT_STATE_SKY_KNOWN;
    }
    if (ground >= 48u) {
        float target = smoothstep(0.20, 0.55, float(snow) / float(ground));
        sunlitGroundCold = (flags & ADV_SUNLIT_STATE_GROUND_KNOWN) != 0u ? mix(sunlitGroundCold, target, 0.03) : target;
        flags |= ADV_SUNLIT_STATE_GROUND_KNOWN;
    }
    sunlitStateFlags = flags;

    bool skyKnown = (flags & ADV_SUNLIT_STATE_SKY_KNOWN) != 0u;
    bool groundKnown = (flags & ADV_SUNLIT_STATE_GROUND_KNOWN) != 0u;
    bool skyFresh = skyKnown && distance(camera, vec2(sunlitLatchX, sunlitLatchZ)) < 320.0;
    float target = 0.0;
    if (skyFresh) {
        target = sunlitSkyCold;
    } else if (groundKnown) {
        target = sunlitGroundCold;
    } else if (skyKnown) {
        target = sunlitSkyCold;
    }
    sunlitClimate = clamp(mix(sunlitClimate, target, 0.04), 0.0, 1.0);
    return sunlitClimate;
}
#endif

#endif
