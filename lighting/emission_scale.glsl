#ifndef ADV_LIGHTING_EMISSION_SCALE_GLSL
#define ADV_LIGHTING_EMISSION_SCALE_GLSL

// Sunlit: user brightness for emissive surfaces. Blocks (chunk geometry: torches, lava, glowstone, magma...) and
// everything else (held and dropped items, mobs, block entities) are scaled separately. Applied both to the
// visible glow and to the light the emitters cast, so the two stay consistent.
#ifndef ADV_EMISSION_SCALE
#    define ADV_EMISSION_SCALE 1.0
#endif
#ifndef ADV_BLOCK_EMISSION_SCALE
#    define ADV_BLOCK_EMISSION_SCALE 1.0
#endif
#ifndef ADV_ENTITY_EMISSION_SCALE
#    define ADV_ENTITY_EMISSION_SCALE 1.0
#endif

// Sunlit: extra brightness multipliers (on top of the block brightness above) for three blocks that are far too
// bright for their light level: Magma Block, lit Redstone Ore and Glow Lichen. 1.0 = unchanged, 0.0 = no glow and
// no light at all. They scale both the visible glow and the light the block casts.
#ifndef ADV_MAGMA_EMISSION
#    define ADV_MAGMA_EMISSION 0.25
#endif
#ifndef ADV_REDSTONE_ORE_EMISSION
#    define ADV_REDSTONE_ORE_EMISSION 0.25
#endif
#ifndef ADV_GLOW_LICHEN_EMISSION
#    define ADV_GLOW_LICHEN_EMISSION 0.15
#endif

float sunlitEmissionScale(bool isChunkGeometry) {
    float scale = isChunkGeometry ? float(ADV_BLOCK_EMISSION_SCALE) : float(ADV_ENTITY_EMISSION_SCALE);
    return max(scale * float(ADV_EMISSION_SCALE), 0.0);
}

// How the three blocks are recognised. Everything below is exact bookkeeping, not a colour guess, so no other
// emissive block (torches, lanterns, lava, glowstone, campfires...) can be caught by accident:
//   * the vertex emission of a block is its Minecraft light level / 15
//       Magma Block 3 -> 0.200, Glow Lichen 7 -> 0.467, lit Redstone Ore 9 -> 0.600
//     (torch 14 -> 0.933, lava / glowstone / sea lantern / shroomlight 15 -> 1.0, ...);
//   * all three are drawn as FULL 1x1 block faces (triangle area 0.5, polygon area 1.0), while torches, lanterns,
//     candles, redstone torches and sea pickles have only tiny faces (< 0.25);
//   * Magma Block and Redstone Ore are opaque cubes, Glow Lichen is a thin cutout decal.
const float SUNLIT_LIGHT_LEVEL_UNIT = 1.0 / 15.0;
const float SUNLIT_LIGHT_LEVEL_TOLERANCE = 0.03;  // adjacent light levels are 0.067 apart
const float SUNLIT_FULL_FACE_MIN_AREA = 0.40;

bool sunlitIsLightLevel(float emission, float level) {
    return abs(emission - level * SUNLIT_LIGHT_LEVEL_UNIT) < SUNLIT_LIGHT_LEVEL_TOLERANCE;
}

// Scales down the direct light cast by Magma Block, lit Redstone Ore and Glow Lichen in ReSTIR / RIS.
// `radiance.a` is the emission strength of the packed light (the same light level / 15 as above); the rgb part is
// the colour. Only full-face emitters are looked at.
float sunlitPackedLightAdjustment(vec4 p0Area, vec4 normal, vec4 radiance) {
    if (p0Area.w < SUNLIT_FULL_FACE_MIN_AREA) { return 1.0; }
    float emission = radiance.a;

    if (sunlitIsLightLevel(emission, 3.0)) { return clamp(float(ADV_MAGMA_EMISSION), 0.0, 1.0); }
    if (sunlitIsLightLevel(emission, 9.0)) { return clamp(float(ADV_REDSTONE_ORE_EMISSION), 0.0, 1.0); }
    if (sunlitIsLightLevel(emission, 7.0)) {
        // Glow Lichen decals sit a hair off the block grid (not exactly on it, not far from it); this keeps other
        // light level 7 blocks such as the enchanting table (top face at 0.75) untouched.
        vec3 absN = abs(normal.xyz);
        float planeCoord = absN.x > 0.5 ? p0Area.x : (absN.y > 0.5 ? p0Area.y : p0Area.z);
        float gridOffset = abs(fract(planeCoord + 0.5) - 0.5);
        if (gridOffset > 0.002 && gridOffset < 0.10) { return clamp(float(ADV_GLOW_LICHEN_EMISSION), 0.0, 1.0); }
    }
    return 1.0;
}

// Scales the glow of Magma Block, lit Redstone Ore and Glow Lichen. Nothing else is touched: for every other
// block this function returns immediately, so torches, lanterns, lava, glowstone etc. keep their normal glow.
//
// Note: a surface with ANY glow is treated as an emitter and does not receive direct light from other lights. So
// the parts of these blocks that should not glow (magma crust, the stone of redstone ore) are set to exactly 0
// and light up normally, and only the glowing texels keep a (scaled) emission. The masks are smooth, so mip
// filtering at a distance fades them instead of flipping.
//   rawAlbedo   texel colour as stored in the atlas (sRGB-encoded)
//   faceArea    world-space area of the hit triangle
void sunlitAdjustBlockSurfaceEmission(uint alphaMode,
                                      vec3 rawAlbedo,
                                      float vertexEmission,
                                      float faceArea,
                                      bool isChunkGeometry,
                                      inout float emissionAmount) {
    if (!isChunkGeometry || emissionAmount <= 1e-4 || faceArea < SUNLIT_FULL_FACE_MIN_AREA) { return; }
    bool isOpaque = alphaMode == 0u;  // ALPHA_MODE_OPAQUE

    // Magma Block (opaque cube, light level 3): only the bright orange/yellow cracks glow, the dark crust does not.
    if (isOpaque && sunlitIsLightLevel(vertexEmission, 3.0)) {
        float crackMask = smoothstep(0.30, 0.65, max(rawAlbedo.r, rawAlbedo.g));
        emissionAmount *= crackMask * clamp(float(ADV_MAGMA_EMISSION), 0.0, 1.0);
        return;
    }

    // Lit Redstone Ore (opaque cube, light level 9): grey stone does not glow, only the red specks do.
    if (isOpaque && sunlitIsLightLevel(vertexEmission, 9.0)) {
        float redness = rawAlbedo.r - max(rawAlbedo.g, rawAlbedo.b);
        float speckMask = smoothstep(0.03, 0.40, redness);
        emissionAmount *= speckMask * clamp(float(ADV_REDSTONE_ORE_EMISSION), 0.0, 1.0);
        return;
    }

    // Glow Lichen (cutout decal, light level 7): the whole decal is simply dimmed.
    if (!isOpaque && sunlitIsLightLevel(vertexEmission, 7.0)) {
        emissionAmount *= clamp(float(ADV_GLOW_LICHEN_EMISSION), 0.0, 1.0);
    }
}

#endif
