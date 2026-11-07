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
// Master toggle for per-block emission adjustments (magma, redstone ore, glow lichen).
#ifndef ADV_CUSTOM_BLOCK_EMISSION
#    define ADV_CUSTOM_BLOCK_EMISSION 1
#endif
#ifndef ADV_MAGMA_EMISSION_SCALE
#    define ADV_MAGMA_EMISSION_SCALE 0.12
#endif
#ifndef ADV_REDSTONE_ORE_EMISSION_SCALE
#    define ADV_REDSTONE_ORE_EMISSION_SCALE 0.15
#endif
#ifndef ADV_GLOW_LICHEN_EMISSION_SCALE
#    define ADV_GLOW_LICHEN_EMISSION_SCALE 3.5
#endif

float sunlitEmissionScale(bool isChunkGeometry) {
    float scale = isChunkGeometry ? float(ADV_BLOCK_EMISSION_SCALE) : float(ADV_ENTITY_EMISSION_SCALE);
    return max(scale * float(ADV_EMISSION_SCALE), 0.0);
}

// Scales direct light sources (PackedLight in ChunkLights for RIS and ReSTIR) coming from magma, redstone ore,
// and glow lichen, both when placed in the world (isEntityLight == false) and when held in hand or dropped as an
// item (isEntityLight == true).
float sunlitPackedLightScale(
    vec3 p0, vec3 p1, vec3 p2, vec3 p3, vec3 normal, vec4 radiance, bool isEntityLight) {
#if ADV_CUSTOM_BLOCK_EMISSION == 0
    return 1.0;
#else
    float magmaTarget = clamp(float(ADV_MAGMA_EMISSION_SCALE), 0.0, 1.0);
    float redstoneTarget = clamp(float(ADV_REDSTONE_ORE_EMISSION_SCALE), 0.0, 1.0);
    float lichenTarget = clamp(float(ADV_GLOW_LICHEN_EMISSION_SCALE), 0.0, 100.0);

    float planeOffset = 0.0;
    float signedOffset = 0.0;
    float nAxis = 1.0;
    if (!isEntityLight) {
        vec3 n = dot(normal, normal) > 0.5 ? normalize(normal) : normalize(cross(p1 - p0, p2 - p0));
        vec3 absN = abs(n);
        // Placed block: must be an axis-aligned block face (excludes tilted wall torches, etc.).
        if (max(absN.x, max(absN.y, absN.z)) < 0.95) { return 1.0; }

        // Coordinate of the face plane along its normal.
        // Placed 1x1x1 cube blocks sit at 0.0; placed glow lichen sits at 0.1/16 = 0.00625 from the block face.
        // Torches (7/16, 9/16, 10/16), lanterns (5/16, 11/16), candles (7/16), end rods (6/16), and still lava top
        // faces (14/16 = 0.875) have large fractional offsets and are excluded here.
        float planeCoord = absN.x > 0.5 ? p0.x : (absN.y > 0.5 ? p0.y : p0.z);
        nAxis = absN.x > 0.5 ? n.x : (absN.y > 0.5 ? n.y : n.z);
        signedOffset = planeCoord - round(planeCoord);
        planeOffset = abs(signedOffset);
        if (planeOffset > 0.03) { return 1.0; }

        // Exclude vertical side faces of 14/16 still lava (whose top edge sits at Y + 0.875).
        vec3 minP = min(min(p0, p1), min(p2, p3));
        vec3 maxP = max(max(p0, p1), max(p2, p3));
        if (absN.y < 0.5 && abs((maxP.y - minP.y) - 0.875) < 0.02 && abs(maxP.y - round(maxP.y)) > 0.10) {
            return 1.0;
        }
    }

    vec3 rad = max(radiance.rgb, vec3(0.0));
    float maxCh = max(rad.r, max(rad.g, rad.b));
    if (maxCh <= 1e-6) { return 1.0; }
    float weight = radiance.a > 0.0 ? radiance.a : 1.0;
    float effMax = maxCh * weight;

    // Redstone ore & deepslate redstone ore: red-dominant emission.
    if (rad.r > rad.g * 1.45 && rad.r > rad.b * 1.45 && rad.g <= rad.b * 1.85 + 0.04 * maxCh) {
        return redstoneTarget;
    }

    // Magma block: warm orange/golden-yellow crack emission (R/G ~ 1.37, G/B ~ 8.5, B/R ~ 0.085).
    float maxBlueRatio = isEntityLight ? 0.24 : 0.33;
    float minRedGreenRatio = isEntityLight ? 1.22 : 1.05;
    if (rad.r > rad.g * minRedGreenRatio && rad.g > rad.b * 2.20 && rad.b < rad.r * maxBlueRatio) {
        return magmaTarget;
    }

    // Glow lichen: muted warm-cream / sage-green spectrum, and either placed as a decal plane (offset ~0.00625 from
    // the block face) or having Radiance's low internal specular emission (bin 0, effMax < 0.22).
    bool looksLikeLichenColor = rad.r > rad.g * 0.72 && rad.r < rad.g * 1.35 &&
                                rad.b > rad.r * 0.28 && rad.b < max(rad.r, rad.g) * 0.96;
    bool isPlacedLichenDecal = !isEntityLight && planeOffset > 0.002 && planeOffset < 0.025;
    if (isPlacedLichenDecal) {
        // The back face of the decal points into the wall 6 mm behind it (nAxis * signedOffset < 0) and would create
        // a sharp glowing outline around each texel on the wall; suppress the back face and only boost the front face.
        if (nAxis * signedOffset < 0.0) { return 0.0; }
        if (looksLikeLichenColor) { return lichenTarget; }
    } else if (looksLikeLichenColor && effMax < 0.22) {
        return lichenTarget;
    }

    return 1.0;
#endif
}

// Used only on secondary / GI bounce rays so magma, redstone ore, and glow lichen keep their normal visual appearance
// when viewed directly by the camera, while scaling the indirect light they bounce onto surrounding surfaces.
float sunlitBlockTextureEmissionScale(sampler2D albedoTex,
                                      sampler2D specularTex,
                                      vec2 atlasMin,
                                      vec2 atlasMax,
                                      vec3 texelAlbedoSrgb,
                                      float rawTextureEmission,
                                      float faceArea,
                                      float rayDistance,
                                      uint alphaMode,
                                      bool isChunkGeometry) {
#if ADV_CUSTOM_BLOCK_EMISSION == 0
    return 1.0;
#else
    if (rawTextureEmission <= 0.001) { return 1.0; }

    // Prevent secondary GI rays launched from a wall directly under a 6 mm cutout decal (glow lichen) from picking up
    // back-face emission and forming a glowing outline around the decal's texels.
    if (isChunkGeometry && alphaMode != 0u && rayDistance < 0.08) {
        return 0.0;
    }

    float magmaTarget = clamp(float(ADV_MAGMA_EMISSION_SCALE), 0.0, 1.0);
    float redstoneTarget = clamp(float(ADV_REDSTONE_ORE_EMISSION_SCALE), 0.0, 1.0);
    float lichenTarget = clamp(float(ADV_GLOW_LICHEN_EMISSION_SCALE), 0.0, 100.0);
    if (magmaTarget >= 0.999 && redstoneTarget >= 0.999 && abs(lichenTarget - 1.0) < 0.001) { return 1.0; }

    // Glow lichen: cutout material (alphaMode != 0) or held/dropped item with low built-in specular emission (< 0.22)
    // and warm-cream / sage-green texel colour.
    bool looksLikeLichenTexel = texelAlbedoSrgb.r > texelAlbedoSrgb.g * 0.72 &&
                                texelAlbedoSrgb.r < texelAlbedoSrgb.g * 1.35 &&
                                texelAlbedoSrgb.b > texelAlbedoSrgb.r * 0.28 &&
                                texelAlbedoSrgb.b < max(texelAlbedoSrgb.r, texelAlbedoSrgb.g) * 0.96;
    if (rawTextureEmission < 0.22 && (!isChunkGeometry || alphaMode != 0u) && looksLikeLichenTexel) {
        return lichenTarget;
    }

    if (isChunkGeometry && (alphaMode != 0u || faceArea < 0.40)) { return 1.0; }

    bool looksLikeRedstoneSpeck = texelAlbedoSrgb.r > 0.28 &&
                                  texelAlbedoSrgb.r > texelAlbedoSrgb.g * 1.50 &&
                                  texelAlbedoSrgb.r > texelAlbedoSrgb.b * 1.50 &&
                                  texelAlbedoSrgb.g <= texelAlbedoSrgb.b * 1.60 + 0.04;
    bool looksLikeMagmaCrack = texelAlbedoSrgb.r > 0.35 &&
                               texelAlbedoSrgb.g > 0.06 &&
                               texelAlbedoSrgb.b < 0.50 &&
                               texelAlbedoSrgb.r >= texelAlbedoSrgb.g * 0.95 &&
                               texelAlbedoSrgb.g > texelAlbedoSrgb.b * 1.25;
    if (!looksLikeRedstoneSpeck && !looksLikeMagmaCrack) { return 1.0; }

    ivec2 specSize = textureSize(specularTex, 0);
    ivec2 albSize = textureSize(albedoTex, 0);
    if (specSize.x <= 0 || specSize.y <= 0 || albSize.x <= 0 || albSize.y <= 0) { return 1.0; }

    vec2 minUv = min(atlasMin, atlasMax);
    vec2 maxUv = max(atlasMin, atlasMax);
    int unlitCount = 0;
    vec3 unlitAlbedoSum = vec3(0.0);

    for (int iy = 0; iy < 3; ++iy) {
        for (int ix = 0; ix < 3; ++ix) {
            vec2 sampleUv = mix(minUv, maxUv, (vec2(float(ix), float(iy)) + 0.5) * (1.0 / 3.0));
            ivec2 specCoord = clamp(ivec2(floor(sampleUv * vec2(specSize))), ivec2(0), specSize - ivec2(1));
            float specA = texelFetch(specularTex, specCoord, 0).a;
            int intEm = int(round(specA * 255.0));
            if (intEm == 0 || intEm == 255) {
                ivec2 albCoord = clamp(ivec2(floor(sampleUv * vec2(albSize))), ivec2(0), albSize - ivec2(1));
                unlitAlbedoSum += texelFetch(albedoTex, albCoord, 0).rgb;
                ++unlitCount;
            }
        }
    }

    if (unlitCount < 4) { return 1.0; }

    vec3 unlitAlbedo = unlitAlbedoSum / float(unlitCount);
    float unlitMax = max(unlitAlbedo.r, max(unlitAlbedo.g, unlitAlbedo.b));
    float unlitMin = min(unlitAlbedo.r, min(unlitAlbedo.g, unlitAlbedo.b));
    float unlitChroma = unlitMax - unlitMin;

    if (looksLikeRedstoneSpeck && unlitChroma < 0.14) {
        return rawTextureEmission > 0.5 ? redstoneTarget : min(rawTextureEmission, redstoneTarget) / rawTextureEmission;
    }

    if (looksLikeMagmaCrack && unlitMax < 0.38) {
        return rawTextureEmission > 0.5 ? magmaTarget : min(rawTextureEmission, magmaTarget) / rawTextureEmission;
    }

    return 1.0;
#endif
}

#endif