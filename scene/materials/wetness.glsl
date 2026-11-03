#ifndef ADV_SCENE_MATERIALS_WETNESS_GLSL
#define ADV_SCENE_MATERIALS_WETNESS_GLSL

#ifndef ADV_RAIN_WETNESS_ENABLED
#define ADV_RAIN_WETNESS_ENABLED 1
#endif

ivec4 rainColumn(ivec2 column, uint textureId) {
    return ivec4(round(texelFetch(textures[nonuniformEXT(textureId)], column & ivec2(511), 0) * 255.0));
}

bool rainColumnBlocks(ivec4 data, int surfaceBlockY) {
    return data.a == 0 || (data.r + 256 * data.g - 32768) > surfaceBlockY;
}

// Only treat a neighbouring column as a roof/overhang if its blocker is at least 2 blocks above the ground surface,
// so a single block sitting on the grass does not carve a geometric dry ring around itself.
bool rainNeighborOverhangBlocks(ivec4 data, int surfaceBlockY) {
    return data.a == 0 || (data.r + 256 * data.g - 32768) > surfaceBlockY + 1;
}

float wetnessHash2(ivec2 p) {
    uvec2 q = uvec2(p + ivec2(1073741824));
    uint h = q.x * 0x8da6b343u ^ q.y * 0xd8163841u ^ 0x2545f491u;
    h ^= h >> 16u;
    h *= 0x7feb352du;
    h ^= h >> 15u;
    h *= 0x846ca68bu;
    h ^= h >> 16u;
    return float(h >> 8u) * (1.0 / 16777216.0);
}

float wetnessNoise2(vec2 p) {
    vec2 i = floor(p);
    vec2 f = p - i;
    vec2 u = f * f * (3.0 - 2.0 * f);
    ivec2 c = ivec2(i);
    float a = wetnessHash2(c);
    float b = wetnessHash2(c + ivec2(1, 0));
    float d = wetnessHash2(c + ivec2(0, 1));
    float e = wetnessHash2(c + ivec2(1, 1));
    return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

float wetnessFbm(vec2 p) {
    float sum = 0.0;
    float amp = 0.5;
    mat2 rot = mat2(0.80, -0.60, 0.60, 0.80);
    for (int i = 0; i < 4; ++i) {
        sum += amp * wetnessNoise2(p);
        p = rot * p * 2.05 + vec2(3.7, -1.9);
        amp *= 0.5;
    }
    return sum / 0.9375;
}

float groundWetness(vec3 position, vec3 outwardNormal) {
#if ADV_RAIN_WETNESS_ENABLED == 0
    return 0.0;
#else
    uint textureId = skyUBO.rainData & 65535u;
    float rain = float(skyUBO.rainData >> 16u) / 65535.0;
    if (textureId == 0u || rain <= 0.0001 || outwardNormal.y < 0.5) return 0.0;
    if (max(abs(position.x), abs(position.z)) > 238.0) return 0.0;

    ivec3 cameraCell = ivec3(worldUBO.cameraPos.xyz);
    vec3 relativePosition = position + vec3(worldUBO.cameraPos.xyz - dvec3(cameraCell));
    vec2 worldXZ = vec2(cameraCell.xz) + relativePosition.xz;
    int surfaceBlockY = cameraCell.y + int(floor(relativePosition.y - 0.001));

    // Check if the current block itself is directly under a roof.
    ivec2 baseColumn = cameraCell.xz + ivec2(floor(relativePosition.xz));
    ivec4 center = rainColumn(baseColumn, textureId);
    if (center.b == 0 || rainColumnBlocks(center, surfaceBlockY)) return 0.0;

    // Organic domain warp so shelter edges under roofs/trees are irregular rather than straight lines and circles.
    vec2 warp = vec2(wetnessNoise2(worldXZ * 1.35 + vec2(2.1, -4.7)),
                     wetnessNoise2(worldXZ * 1.35 + vec2(-6.3, 1.8))) - 0.5;
    vec2 warpedRelXZ = relativePosition.xz + warp * 0.42;
    ivec2 column = cameraCell.xz + ivec2(floor(warpedRelXZ));
    vec2 withinColumn = fract(warpedRelXZ);
    ivec2 nearestSide = ivec2(step(vec2(0.5), withinColumn)) * 2 - 1;
    vec2 edge = min(withinColumn, vec2(1.0) - withinColumn);

    float edgeDistanceSquared = 0.25;
    if (rainNeighborOverhangBlocks(rainColumn(column + ivec2(nearestSide.x, 0), textureId), surfaceBlockY))
        edgeDistanceSquared = min(edgeDistanceSquared, edge.x * edge.x);
    if (rainNeighborOverhangBlocks(rainColumn(column + ivec2(0, nearestSide.y), textureId), surfaceBlockY))
        edgeDistanceSquared = min(edgeDistanceSquared, edge.y * edge.y);
    if (rainNeighborOverhangBlocks(rainColumn(column + nearestSide, textureId), surfaceBlockY))
        edgeDistanceSquared = min(edgeDistanceSquared, dot(edge, edge));

    float shelterFade = smoothstep(0.02, 0.48, sqrt(edgeDistanceSquared));
    if (shelterFade <= 0.001) return 0.0;

    // Multi-scale organic puddle map: damp ground everywhere in rain (0.15..0.45) + irregular puddles (0.55..1.0).
    float puddleMacro = wetnessFbm(worldXZ * 0.22 + warp * 0.35);
    float puddleDetail = wetnessNoise2(worldXZ * 1.80 - warp * 0.8);
    float puddleField = puddleMacro * 0.78 + puddleDetail * 0.22;
    float puddles = smoothstep(0.46, 0.68, puddleField);

    rain *= 1.0 - smoothstep(220.0, 238.0, max(abs(position.x), abs(position.z)));
    float slopeFactor = smoothstep(0.5, 0.95, outwardNormal.y);
    float combinedWetness = mix(0.28 + 0.14 * puddleMacro, 1.0, puddles);
    return rain * shelterFade * slopeFactor * combinedWetness;
#endif
}

void applyGroundWetness(inout LabPBRMat material, float wetness) {
    if (wetness <= 0.0 || material.transmission > 0.0) return;
    float absorbency = (1.0 - material.metallic) * clamp(material.roughness * 2.0, 0.0, 1.0);
    // Dampness darkens porous blocks everywhere; standing water in puddles (> 0.5) creates smooth glossy patches.
    float damp = clamp(wetness * 1.8, 0.0, 1.0);
    float puddle = smoothstep(0.48, 0.88, wetness);
    material.albedo *= 1.0 - (0.24 * damp + 0.16 * puddle) * absorbency;
    float dampRoughness = min(material.roughness, mix(material.roughness, 0.42, damp));
    material.roughness = mix(dampRoughness, min(material.roughness, 0.05), puddle);
    material.f0 = mix(material.f0, max(material.f0, vec3(0.03)), puddle * 0.65);
}

#endif