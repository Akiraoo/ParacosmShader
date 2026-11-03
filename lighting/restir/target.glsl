#ifndef ADV_LIGHTING_RESTIR_TARGET_GLSL
#define ADV_LIGHTING_RESTIR_TARGET_GLSL

#include "lighting/restir/packing.glsl"

// Sunlit: with linear albedo, surfaces reflect ~2.2x less (mid-grey 0.5 -> 0.21), so light from torches and other
// emitters is scaled to keep caves and torch-lit rooms as bright as in Advanced.
#ifndef ADV_EMITTER_LIGHT_COMPENSATION
#    if defined(ADV_LINEAR_ALBEDO) && ADV_LINEAR_ALBEDO == 0
#        define ADV_EMITTER_LIGHT_COMPENSATION 1.0
#    else
#        define ADV_EMITTER_LIGHT_COMPENSATION 2.2
#    endif
#endif

#if ADV_LIGHT_SAMPLING_MODE == 1
// RIS (Chromance method): close to a light the inverse square is softened (within about half a block) so the
// block a torch is mounted on does not blow out into a white hot spot, and light can fade out over a set range
// so a torch lights a small area and the rest of a cave stays dark.
const float ADV_RIS_NEAR_SOFTENING = 0.25;

float risBlockLightFade(float distanceToLight) {
    float range = float(ADV_RIS_LIGHT_RANGE);
    if (range <= 0.0) { return 1.0; }
    float t = clamp(distanceToLight / range, 0.0, 1.0);
    float f = 1.0 - t * t;
    return f * f;
}
#endif

RestirTarget invalidRestirTarget() {
    RestirTarget target;
    target.isValid = false;
    target.isSplit = false;
    target.isSecondary = false;
    target.position = vec3(0.0);
    target.parallax = invalidParallaxState();
    target.geometryNormal = vec3(0.0, 1.0, 0.0);
    target.shadingNormal = vec3(0.0, 1.0, 0.0);
    target.viewDirection = vec3(0.0, 0.0, 1.0);
    target.albedo = vec3(0.0);
    target.f0 = vec3(0.04);
    target.throughput = vec3(1.0);
    target.roughness = 1.0;
    target.metallic = 0.0;
    target.opacity = 1.0;
    return target;
}

bool loadRestirTarget(ivec2 flatPixel, ivec2 flatExtent, out RestirTarget target) {
    target = invalidRestirTarget();
    if (any(lessThan(flatPixel, ivec2(0))) || any(greaterThanEqual(flatPixel, flatExtent))) { return false; }

    CheckerCoordinate checker = flatToChecker(flatPixel, flatExtent);
    if (!checker.isValid) { return false; }
    ShadingPath path = loadShadingPath(checker.packedPixel);
    uint flags = pathFlags(path.key);
    uint excludedFlags = ADV_PATH_FLAG_HAND | ADV_PATH_FLAG_CLOUD | ADV_PATH_FLAG_WATER |
                         ADV_PATH_FLAG_FIRST_HIT_CLOUD | ADV_PATH_FLAG_NO_REFLECT | ADV_PATH_FLAG_PORTAL;
    uint surfaceMedium = pathSurfaceMedium(path.key);
    bool isOpaqueSurface = path.opacity >= 1.0 - EPS;
    if (!isPathValid(path.key) || isSkyPath(path.key) || (flags & ADV_PATH_FLAG_TERMINAL_SURFACE) == 0u ||
        (flags & excludedFlags) != 0u || surfaceMedium != ADV_MEDIUM_SOLID || !isOpaqueSurface ||
        !isBrdfFinite(path.roughness) || (flags & ADV_PATH_FLAG_EMISSIVE) != 0u ||
        !isRestirScenePositionWithinPlayerRange(path.position, worldUBO)) {
        return false;
    }

    target.position = path.position;
    target.geometryNormal = brdfNormalize(path.geometryNormal, vec3(0.0, 1.0, 0.0));
    target.shadingNormal = brdfNormalize(path.shadingNormal, target.geometryNormal);
    target.viewDirection = brdfNormalize(-path.rayDirection, target.shadingNormal);
    target.albedo = clamp(path.albedo, vec3(0.0), vec3(1.0));
    target.f0 = clamp(path.f0, vec3(0.0), vec3(1.0));
    target.throughput = max(path.throughput, vec3(0.0));
    target.roughness = clamp(path.roughness, 0.0, 1.0);
    target.metallic = clamp(path.metallic, 0.0, 1.0);
    target.opacity = clamp(path.opacity, 0.0, 1.0);
    target.isSplit = isSplitPath(path.key);
    target.isSecondary = pathBounceCount(path.key) != 0u;
    target.parallax = target.isSecondary ? invalidParallaxState() : path.parallax;
    target.isValid = isBrdfFinite(target.position) && isBrdfFinite(target.geometryNormal) &&
                     isBrdfFinite(target.shadingNormal) && isBrdfFinite(target.viewDirection) &&
                     isBrdfFinite(target.albedo) && isBrdfFinite(target.f0) && isBrdfFinite(target.throughput) &&
                     max(target.throughput.r, max(target.throughput.g, target.throughput.b)) > 1e-6 &&
                     dot(target.geometryNormal, target.geometryNormal) > 1e-8 &&
                     dot(target.shadingNormal, target.shadingNormal) > 1e-8 &&
                     dot(target.viewDirection, target.viewDirection) > 1e-8;
    return target.isValid;
}

float evaluateRestirTarget(RestirTarget target,
                           vec3 lightRadiance,
                           vec3 lightPoint,
                           vec3 lightNormal,
                           out vec3 diffuseContribution,
                           out vec3 lightDirection) {
    diffuseContribution = vec3(0.0);
    lightDirection = vec3(0.0);
    if (!target.isValid || !isBrdfFinite(lightRadiance) || !isBrdfFinite(lightPoint) || !isBrdfFinite(lightNormal)) {
        return 0.0;
    }

    vec3 lightScenePosition = lightPoint - vec3(worldUBO.cameraPos.xyz);
    vec3 lightVector = lightScenePosition - target.position;
    float distanceSquared = dot(lightVector, lightVector);
    if (!isBrdfFinite(distanceSquared) || distanceSquared <= 1e-8) { return 0.0; }
    lightDirection = lightVector * inversesqrt(distanceSquared);
    if (dot(lightDirection, target.geometryNormal) <= 0.0) { return 0.0; }
    float emitterCosine = dot(lightNormal, -lightDirection);
    if (emitterCosine <= 1e-6) { return 0.0; }
#if ADV_LIGHT_SAMPLING_MODE == 1
    float risFade = risBlockLightFade(sqrt(distanceSquared));
    if (risFade <= 0.0) { return 0.0; }
    distanceSquared += ADV_RIS_NEAR_SOFTENING;
#endif

    DirectBrdf brdf =
        evaluateDirectBrdf(target.shadingNormal, lightDirection, target.viewDirection, target.f0, target.roughness);
    vec3 lightScale =
        float(ADV_RESTIR_DIRECT_LIGHT_STRENGTH) * float(ADV_EMITTER_LIGHT_COMPENSATION) * max(lightRadiance, vec3(0.0)) *
        (emitterCosine / distanceSquared);
#if ADV_LIGHT_SAMPLING_MODE == 1
    lightScale *= risFade;
#endif
    vec3 materialDiffuseAlbedo = diffuseAlbedo(target.albedo, target.metallic) * target.opacity;
    diffuseContribution = lightScale * brdf.diffuse * materialDiffuseAlbedo * target.throughput;
    if (!isBrdfFinite(diffuseContribution)) { diffuseContribution = vec3(0.0); }
    return luminance(max(diffuseContribution, vec3(0.0)));
}

float evaluateRestirTarget(RestirTarget target, vec3 lightRadiance, vec3 lightPoint, vec3 lightNormal) {
    vec3 diffuseContribution;
    vec3 lightDirection;
    return evaluateRestirTarget(target, lightRadiance, lightPoint, lightNormal, diffuseContribution, lightDirection);
}

bool isRestirReuseStable(RestirTarget target, RestirReservoir reservoir, vec3 donorWorldPosition) {
    vec3 receiverToLight = (reservoir.point - vec3(worldUBO.cameraPos.xyz)) - target.position;
    return reservoir.isValid &&
           isRestirGeometryTransferStable(reservoir.point - donorWorldPosition, receiverToLight, reservoir.normal);
}

#endif
