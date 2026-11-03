#ifndef ADV_SCENE_MATERIALS_ALPHA_GLSL
#define ADV_SCENE_MATERIALS_ALPHA_GLSL

#include "util/alpha_mode.glsl"

#ifndef ADV_WAVING_FOLIAGE
#    define ADV_WAVING_FOLIAGE 1
#endif

const float ADV_ALPHA_BLEND_COVERAGE_THRESHOLD = 0.05;

float alphaCoverageThreshold(uint alphaMode) {
    if (alphaMode == ALPHA_MODE_TRANSPARENT) { return ADV_ALPHA_BLEND_COVERAGE_THRESHOLD; }
    return alphaCutoutThreshold(alphaMode);
}

bool isAlphaCovered(float rawAlpha, uint alphaMode) {
    if (alphaMode == ALPHA_MODE_OPAQUE) { return true; }
    return clamp(rawAlpha, 0.0, 1.0) >= alphaCoverageThreshold(alphaMode);
}

float remapAlphaBlendedOpacity(float alpha) {
    alpha = clamp(alpha, 0.0, 1.0);
    if (alpha >= 0.99) { return alpha; }
    return clamp((alpha - 0.5) * 2.0, 0.0, 1.0);
}

float resolveSurfaceOpacity(float rawAlpha, uint alphaMode) {
    if (alphaMode == ALPHA_MODE_TRANSPARENT) { return remapAlphaBlendedOpacity(clamp(rawAlpha, 0.0, 1.0)); }
    return resolveSurfaceAlpha(rawAlpha, alphaMode);
}

vec3 alphaBlendedTransmission(vec3 tint, float opacity) {
    return clamp(tint, vec3(0.0), vec3(1.0)) * (1.0 - clamp(opacity, 0.0, 1.0));
}

// Coherent 3D-projected wind sway for plants (short/tall grass, ferns, sugar cane, flowers, saplings, crops).
// Uses pure vertex/geometry attributes (no sampler2D forwarding) so it is 100% safe across all Vulkan drivers,
// never twists cube blocks (grass_block, leaves), and never moves stalactites/stalagmites (pointed_dripstone).
vec2 applyFoliageWindUv(vec2 uv,
                        vec2 uv0,
                        vec2 uv1,
                        vec2 uv2,
                        vec2 atlasMin,
                        vec2 atlasMax,
                        vec3 localP0,
                        vec3 localP1,
                        vec3 localP2,
                        vec3 worldPos,
                        uint packedData,
                        vec4 colorLayer,
                        float vertexEmission,
                        bool isChunkGeometry,
                        float gameTime,
                        out bool outOfBounds) {
    outOfBounds = false;
#if ADV_WAVING_FOLIAGE == 0
    return uv;
#else
    if (!isChunkGeometry || vertexEmission > 0.001) { return uv; }
    uint alphaMode = getSurfaceAlphaMode(packedData);
    if (alphaMode != ALPHA_MODE_CUTOUT && alphaMode != ALPHA_MODE_CUTOUT_TENTH &&
        alphaMode != ALPHA_MODE_CUTOUT_EPSILON) {
        return uv;
    }

    vec3 edge1 = localP1 - localP0;
    vec3 edge2 = localP2 - localP0;
    vec3 crossN = cross(edge1, edge2);
    float len2 = dot(crossN, crossN);
    if (len2 <= 1e-10) { return uv; }
    vec3 localNormal = crossN * inversesqrt(len2);

    // Only vertical planes can be cross-plants or crops (excludes horizontal block tops/bottoms completely).
    if (abs(localNormal.y) >= 0.15) { return uv; }

    // 1. Diagonal cross-quads (45 degrees in XZ).
    bool isDiagonalQuad = abs(localNormal.x) > 0.35 && abs(localNormal.z) > 0.35;

    // 2. Inset crop planes at 0.25 / 0.75 inside the block: wheat, carrots, potatoes, beetroot.
    bool isCropPlane = false;
    if (!isDiagonalQuad) {
        float planeCoord = abs(localNormal.x) > 0.5 ? localP0.x : localP0.z;
        float pf = fract(planeCoord);
        isCropPlane = abs(pf - 0.25) < 0.045 || abs(pf - 0.75) < 0.045;
    }

    if (!isDiagonalQuad && !isCropPlane) { return uv; }

    // Distinguish ground plants from pointed_dripstone (stalactites/stalagmites):
    // - Grass, tall grass, ferns, large ferns, sugar cane have green vertex biome tint.
    // - Flowers have a smaller quad span (< 0.85 blocks) or larger random XZ model offset than dripstone.
    bool hasGreenBiomeTint = (packedData & 1u) != 0u &&
                             colorLayer.g > colorLayer.r * 1.02 &&
                             colorLayer.g > colorLayer.b * 1.04;
    float quadWidthXZ = length(max(localP0.xz, max(localP1.xz, localP2.xz)) -
                               min(localP0.xz, min(localP1.xz, localP2.xz)));
    bool isSmallFlowerQuad = quadWidthXZ < 1.15;
    if (isDiagonalQuad && !hasGreenBiomeTint && !isSmallFlowerQuad) {
        return uv;
    }

    vec2 minUv = min(atlasMin, atlasMax);
    vec2 maxUv = max(atlasMin, atlasMax);
    vec2 span = max(maxUv - minUv, vec2(1e-6));

    // Compute the quad's horizontal texture tangent in XZ so both crossing planes of a plant tilt in the same 3D direction.
    vec2 duv1 = uv1 - uv0;
    vec2 duv2 = uv2 - uv0;
    vec2 dp1 = localP1.xz - localP0.xz;
    vec2 dp2 = localP2.xz - localP0.xz;
    vec2 tangentU = dp1 * duv2.y - dp2 * duv1.y;
    float tangentLen2 = dot(tangentU, tangentU);
    vec2 uAxisXZ = tangentLen2 > 1e-10 ? tangentU * inversesqrt(tangentLen2) : vec2(1.0, 0.0);

    // Evaluate wind per block column floor(worldPos.xz) so the whole plant moves coherently without internal warping.
    vec2 blockColumn = floor(worldPos.xz);
    float windTime = gameTime * 6.28318530717958648 * 240.0;
    float phase = dot(blockColumn, vec2(0.85, 0.65));
    float gust = 0.72 + 0.28 * sin(windTime * 0.35 + blockColumn.x * 0.22 + blockColumn.y * 0.18);
    vec2 windXZ = vec2(sin(windTime + phase) * 0.75 + sin(windTime * 1.9 + phase * 1.4) * 0.25,
                       cos(windTime * 0.85 + phase * 1.1) * 0.60) * gust;

    // Root-anchored bend: 0 at the bottom of the sprite (maxUv.y), smooth tilt towards the top (minUv.y).
    float height01 = clamp((maxUv.y - uv.y) / span.y, 0.0, 1.0);
    float bend = height01 * (0.45 + 0.55 * height01);
    float amplitude = isDiagonalQuad ? 0.065 : 0.045;
    float deltaU = -dot(windXZ, uAxisXZ) * bend * amplitude * span.x;

    vec2 shiftedUv = vec2(uv.x + deltaU, uv.y);
    if (shiftedUv.x < minUv.x || shiftedUv.x > maxUv.x) {
        outOfBounds = true;
        return clamp(shiftedUv, minUv, maxUv);
    }
    return shiftedUv;
#endif
}

#endif
