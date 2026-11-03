#ifndef ADV_PATH_PRIMARY_TRACE_GLSL
#define ADV_PATH_PRIMARY_TRACE_GLSL

#include "scene/hit.glsl"
#include "path/budget.glsl"
#include "scene/materials/media.glsl"
#include "util/ray_cone.glsl"

#ifndef ADV_PRIMARY_MISS_INDEX
#    define ADV_PRIMARY_MISS_INDEX 0
#endif
#ifndef ADV_RAY_FLAGS
#    define ADV_RAY_FLAGS 0x200u
#endif
#ifndef ADV_PRIMARY_MAX_DISTANCE
#    define ADV_PRIMARY_MAX_DISTANCE max(1000.0, float(worldUBO.vistaDistanceBlocks))
#endif

const float ADV_PRIMARY_T_MIN = 0.001;

// Sunlit: optionally show the player's own model in first person. Radiance always builds the full player model (it
// is used for shadows and reflections) but Advanced hid it from the camera. With this enabled the camera sees it,
// and only the head - which the camera sits inside - is skipped.
#ifndef ADV_FIRST_PERSON_BODY
#    define ADV_FIRST_PERSON_BODY 0
#endif
// Items-only mode hides the skin and cape and keeps the items held in the model's hands (block/item atlas, shield,
// trident).
#ifndef ADV_FIRST_PERSON_ITEMS_ONLY
#    define ADV_FIRST_PERSON_ITEMS_ONLY 1
#endif
// In items-only mode, also keep the worn armour (armour, trims, elytra) floating around the camera.
#ifndef ADV_FIRST_PERSON_SHOW_ARMOR
#    define ADV_FIRST_PERSON_SHOW_ARMOR 0
#endif
// Upper bound on hidden player layers skipped along one ray (skin, overlay, armour, trim, front and back faces).
#define ADV_FIRST_PERSON_MAX_LAYERS 12

const uint ADV_FIRST_PERSON_UNKNOWN_TEXTURE = 0xffffffffu;
const uint ADV_FIRST_PERSON_STATE_MAGIC = 0x5375e1a7u;
const uint ADV_FIRST_PERSON_PART_HIDDEN = 0u;
const uint ADV_FIRST_PERSON_PART_ITEM = 1u;
const uint ADV_FIRST_PERSON_PART_ARMOR = 2u;

#if ADV_FIRST_PERSON_BODY != 0
#    include "core/bindings.glsl"
// Chunks are always textured from the block atlas, so a terrain hit tells us its texture ID; held items use the
// same atlas. The discover pass stores it here so pixels that see no terrain (sky, entities) know it too.
layout(std430, set = 5, binding = ADV_FIRST_PERSON_STATE_BINDING)
#    ifndef ADV_FIRST_PERSON_LEARN_ATLAS
    readonly
#    endif
    buffer FirstPersonStateBuffer {
    uint firstPersonStateMagic;
    uint firstPersonBlockAtlasTexture;
    uint firstPersonStatePad0;
    uint firstPersonStatePad1;
};
#endif

bool isPrimaryTraceFinite(vec3 vector) {
    return !any(isnan(vector)) && !any(isinf(vector));
}

vec3 primaryTraceNormalize(vec3 vector, vec3 fallback) {
    float lengthSquared = dot(vector, vector);
    if (!isPrimaryTraceFinite(vector) || isnan(lengthSquared) || isinf(lengthSquared) || lengthSquared <= 1e-12) {
        return fallback;
    }
    return vector * inversesqrt(lengthSquared);
}

bool isInsideFirstPersonHead(vec3 position) {
    vec3 eye = worldUBO.cameraViewMatInv[3].xyz;
    vec3 neck = eye - vec3(0.0, 0.12, 0.0);
    vec3 right = primaryTraceNormalize(worldUBO.cameraViewMatInv[0].xyz, vec3(1.0, 0.0, 0.0));
    vec3 up = primaryTraceNormalize(worldUBO.cameraViewMatInv[1].xyz, vec3(0.0, 1.0, 0.0));
    vec3 forward = -primaryTraceNormalize(worldUBO.cameraViewMatInv[2].xyz, vec3(0.0, 0.0, 1.0));
    // The head (plus hat layer) is a 0.5-block cube pivoting at the neck and following the camera's yaw and pitch,
    // so test it in the camera's rotated frame.
    vec3 offset = position - neck;
    vec3 local = vec3(dot(offset, right), dot(offset, up), dot(offset, forward));
    return abs(local.x) < 0.34 && local.y > -0.06 && local.y < 0.62 && abs(local.z) < 0.34;
}

void buildPrimaryCameraRay(
    ivec2 flatPixel, ivec2 flatExtent, out vec3 origin, out vec3 direction, out float coneSpread) {
    vec2 pixelCenter = vec2(flatPixel) + 0.5 + worldUBO.cameraJitter;
    vec2 ndc = pixelCenter / vec2(flatExtent) * 2.0 - 1.0;
    vec4 viewNear = worldUBO.cameraProjMatInv * vec4(ndc, 0.0, 1.0);
    origin = worldUBO.cameraEffectedViewMatInv[3].xyz;
    vec3 fallback = primaryTraceNormalize(-worldUBO.cameraEffectedViewMatInv[2].xyz, vec3(0.0, 0.0, -1.0));
    if (any(isnan(viewNear)) || any(isinf(viewNear)) || abs(viewNear.w) <= 1e-8) {
        direction = fallback;
    } else {
        viewNear /= viewNear.w;
        direction = primaryTraceNormalize(vec3(worldUBO.cameraEffectedViewMatInv * vec4(viewNear.xyz, 0.0)), fallback);
    }
    coneSpread =
        coneSpreadFromFov(fovYFromProj(worldUBO.cameraProjMat), fovXFromProj(worldUBO.cameraProjMat), vec2(flatExtent));
}

#if ADV_FIRST_PERSON_BODY != 0
// Distance along the ray at which it leaves the head box (0 when the origin is outside it). Primary camera rays all
// start inside the head, so the player-only trace starts here instead of stepping through every head layer.
float firstPersonHeadExitDistance(vec3 origin, vec3 direction) {
    vec3 eye = worldUBO.cameraViewMatInv[3].xyz;
    vec3 neck = eye - vec3(0.0, 0.12, 0.0);
    vec3 right = primaryTraceNormalize(worldUBO.cameraViewMatInv[0].xyz, vec3(1.0, 0.0, 0.0));
    vec3 up = primaryTraceNormalize(worldUBO.cameraViewMatInv[1].xyz, vec3(0.0, 1.0, 0.0));
    vec3 forward = -primaryTraceNormalize(worldUBO.cameraViewMatInv[2].xyz, vec3(0.0, 0.0, 1.0));
    vec3 offset = origin - neck;
    vec3 localOrigin = vec3(dot(offset, right), dot(offset, up), dot(offset, forward));
    vec3 localDirection = vec3(dot(direction, right), dot(direction, up), dot(direction, forward));
    vec3 boxMin = vec3(-0.34, -0.06, -0.34);
    vec3 boxMax = vec3(0.34, 0.62, 0.34);
    if (any(lessThanEqual(localOrigin, boxMin)) || any(greaterThanEqual(localOrigin, boxMax))) { return 0.0; }
    vec3 safeDirection = mix(localDirection, vec3(1e-6), lessThan(abs(localDirection), vec3(1e-6)));
    vec3 t0 = (boxMin - localOrigin) / safeDirection;
    vec3 t1 = (boxMax - localOrigin) / safeDirection;
    vec3 tFar = max(t0, t1);
    float exitDistance = min(tFar.x, min(tFar.y, tFar.z));
    return isnan(exitDistance) || isinf(exitDistance) ? 0.0 : clamp(exitDistance, 0.0, 2.0);
}

uint firstPersonChunkTexture(HitPayload hit) {
    if (!isHitValid(hit) || !isChunkGeometryBufferIndex(hit.geometryBufferIndex)) {
        return ADV_FIRST_PERSON_UNKNOWN_TEXTURE;
    }
    uint i0, i1, i2;
    loadTriangleIndices(hit.geometryBufferIndex, hit.primitiveId, i0, i1, i2);
    uvec2 flagsAndTexture = loadMaterialFlagsAndTexture(hit.geometryBufferIndex, i0);
    return hasTexture(flagsAndTexture.x) ? flagsAndTexture.y : ADV_FIRST_PERSON_UNKNOWN_TEXTURE;
}

uint firstPersonBlockAtlas(uint localAtlas) {
#    ifdef ADV_FIRST_PERSON_LEARN_ATLAS
    // A sparse grid of pixels keeps the shared value fresh (after resource reloads the atlas gets a new ID).
    if (localAtlas != ADV_FIRST_PERSON_UNKNOWN_TEXTURE && (gl_LaunchIDEXT.x & 31u) == 0u &&
        (gl_LaunchIDEXT.y & 31u) == 0u &&
        (firstPersonStateMagic != ADV_FIRST_PERSON_STATE_MAGIC || firstPersonBlockAtlasTexture != localAtlas)) {
        firstPersonBlockAtlasTexture = localAtlas;
        firstPersonStateMagic = ADV_FIRST_PERSON_STATE_MAGIC;
    }
#    endif
    if (localAtlas != ADV_FIRST_PERSON_UNKNOWN_TEXTURE) { return localAtlas; }
    return firstPersonStateMagic == ADV_FIRST_PERSON_STATE_MAGIC ? firstPersonBlockAtlasTexture
                                                                  : ADV_FIRST_PERSON_UNKNOWN_TEXTURE;
}

// What a triangle of the player's own model is. Decided from Radiance's per-vertex data, independent of the resource
// pack resolution:
//  * block/item atlas (or any atlas sprite while the block atlas is not known yet) -> held item;
//  * a sprite on another atlas: cutout = armour trims, otherwise banner/shield patterns, beds... -> item;
//  * a whole entity texture: cutout (armor_cutout_no_cull) with a 2:1 texture = armour/elytra, solid (entity_solid)
//    square = shield/trident, solid 2:1 = cape, translucent (entity_translucent) = skin.
uint classifyFirstPersonPlayerPart(HitPayload hit, uint blockAtlas) {
    if (isChunkGeometryBufferIndex(hit.geometryBufferIndex)) { return ADV_FIRST_PERSON_PART_ITEM; }
    uint i0, i1, i2;
    loadTriangleIndices(hit.geometryBufferIndex, hit.primitiveId, i0, i1, i2);
    uvec2 flagsAndTexture = loadMaterialFlagsAndTexture(hit.geometryBufferIndex, i0);
    if (!hasTexture(flagsAndTexture.x)) { return ADV_FIRST_PERSON_PART_HIDDEN; }
    uint textureId = flagsAndTexture.y;
    if (blockAtlas != ADV_FIRST_PERSON_UNKNOWN_TEXTURE && textureId == blockAtlas) {
        return ADV_FIRST_PERSON_PART_ITEM;
    }

    ivec2 textureExtent = textureSize(textures[nonuniformEXT(textureId)], 0);
    vec2 uv0 = loadVertexTextureUV(hit.geometryBufferIndex, i0);
    vec2 uv1 = loadVertexTextureUV(hit.geometryBufferIndex, i1);
    vec2 uv2 = loadVertexTextureUV(hit.geometryBufferIndex, i2);
    vec2 uvExtent = max(uv0, max(uv1, uv2)) - min(uv0, min(uv1, uv2));
    float uvSpan = max(abs(uvExtent.x), abs(uvExtent.y));
    uint alphaMode = getAlphaMode(flagsAndTexture.x);
    bool isCutout = alphaMode == ALPHA_MODE_CUTOUT || alphaMode == ALPHA_MODE_CUTOUT_TENTH ||
                    alphaMode == ALPHA_MODE_CUTOUT_EPSILON;

    // Model faces cover at least 1/16 of an entity texture; an atlas sprite covers a tiny part of a big texture.
    bool isAtlasSprite = max(textureExtent.x, textureExtent.y) >= 256 && uvSpan <= 0.04;
    if (isAtlasSprite) {
        if (blockAtlas != ADV_FIRST_PERSON_UNKNOWN_TEXTURE && isCutout) { return ADV_FIRST_PERSON_PART_ARMOR; }
        return ADV_FIRST_PERSON_PART_ITEM;
    }

    bool isSquare = textureExtent.x == textureExtent.y;
    if (alphaMode == ALPHA_MODE_OPAQUE) { return isSquare ? ADV_FIRST_PERSON_PART_ITEM : ADV_FIRST_PERSON_PART_HIDDEN; }
    if (isCutout) { return isSquare ? ADV_FIRST_PERSON_PART_HIDDEN : ADV_FIRST_PERSON_PART_ARMOR; }
    return ADV_FIRST_PERSON_PART_HIDDEN;
}

bool isFirstPersonVisiblePlayerHit(HitPayload hit, vec3 position, uint blockAtlas) {
    if (isInsideFirstPersonHead(position)) { return false; }
#    if ADV_FIRST_PERSON_ITEMS_ONLY != 0
    uint part = classifyFirstPersonPlayerPart(hit, blockAtlas);
    if (part == ADV_FIRST_PERSON_PART_ITEM) { return true; }
    return part == ADV_FIRST_PERSON_PART_ARMOR && ADV_FIRST_PERSON_SHOW_ARMOR != 0;
#    else
    return true;
#    endif
}
#endif

uint primaryMask(bool isFirstSegment, bool includeHand) {
    uint mask = WORLD_MASK | CLOUD_MASK | BOAT_WATER_MASK;
    if (isFirstSegment) { mask |= FISHING_BOBBER_MASK | WEATHER_MASK | PARTICLE_MASK; }
    if (includeHand) { mask |= HAND_MASK; }
    if (worldUBO.isFirstPerson == 0u || ADV_FIRST_PERSON_BODY != 0) { mask |= PLAYER_MASK; }
    return mask;
}

uint cullFlagsForMedium(uint medium) {
    if (medium == ADV_MEDIUM_CLOUD) { return uint(ADV_RAY_FLAGS); }
    return uint(ADV_RAY_FLAGS) | gl_RayFlagsCullBackFacingTrianglesEXT;
}

HitPayload tracePrimaryHit(vec3 origin,
                           vec3 direction,
                           float tMin,
                           float tMax,
                           float coneWidth,
                           float coneSpread,
                           uint role,
                           uint mask,
                           uint rayFlags) {
    resetHit(hitPayload, coneWidth, coneSpread, role);
    traceRayEXT(topLevelAS, rayFlags, mask, 1, 1, uint(ADV_PRIMARY_MISS_INDEX), origin, tMin, direction, tMax, 0);
    return hitPayload;
}

#if ADV_FIRST_PERSON_BODY != 0
// First person with the player model visible. The world (everything but the player) and the player model are traced
// separately, and hidden player parts are only skipped inside the player-only trace, never past the world hit.
// (Skipping them in a combined trace also skipped world faces lying in the same plane - boot soles on the ground,
// a sleeve against a wall - and the ray then ran through solid terrain, showing caves like spectator mode.)
HitPayload traceFirstPersonSegment(vec3 origin,
                                   vec3 direction,
                                   float tMin,
                                   float coneWidth,
                                   float coneSpread,
                                   bool isFirstSegment,
                                   uint mask,
                                   uint rayFlags) {
    float tMax = float(ADV_PRIMARY_MAX_DISTANCE);
    HitPayload worldHit = tracePrimaryHit(origin, direction, tMin, tMax, coneWidth, coneSpread, ADV_TRACE_ROLE_PRIMARY,
                                          mask & ~PLAYER_MASK, rayFlags);
    uint blockAtlas = firstPersonBlockAtlas(firstPersonChunkTexture(worldHit));
    float playerTMax = isHitValid(worldHit) ? worldHit.hitT : tMax;
    float playerTMin = tMin;
    if (isFirstSegment) { playerTMin = max(playerTMin, firstPersonHeadExitDistance(origin, direction)); }
    for (int layer = 0; layer < ADV_FIRST_PERSON_MAX_LAYERS; ++layer) {
        if (playerTMin >= playerTMax) { break; }
        HitPayload playerHit = tracePrimaryHit(origin, direction, playerTMin, playerTMax, coneWidth, coneSpread,
                                               ADV_TRACE_ROLE_PRIMARY, PLAYER_MASK, rayFlags);
        if (!isHitValid(playerHit)) { break; }
        if (isFirstPersonVisiblePlayerHit(playerHit, origin + direction * playerHit.hitT, blockAtlas)) {
            return playerHit;
        }
        playerTMin = playerHit.hitT + 0.0005;
    }
    return worldHit;
}
#endif

HitPayload findSegmentHitWithTraceLimit(vec3 origin,
                                        vec3 direction,
                                        float coneWidth,
                                        float coneSpread,
                                        uint medium,
                                        bool isFirstSegment,
                                        bool includeHand,
                                        uint traceLimit,
                                        out uint traceCount) {
    float segmentTMin = isFirstSegment ? ADV_PRIMARY_T_MIN : 0.0;
    HitPayload closest;
    resetHit(closest, coneWidth, coneSpread, ADV_TRACE_ROLE_PRIMARY);
    traceCount = 0u;
    if (traceLimit == 0u) { return closest; }

    uint segmentMask = primaryMask(isFirstSegment, includeHand);
    uint segmentRayFlags = isFirstSegment ? uint(ADV_RAY_FLAGS) : cullFlagsForMedium(medium);
#if ADV_FIRST_PERSON_BODY != 0
    if (worldUBO.isFirstPerson != 0u && (segmentMask & PLAYER_MASK) != 0u) {
        closest = traceFirstPersonSegment(origin, direction, segmentTMin, coneWidth, coneSpread, isFirstSegment,
                                          segmentMask, segmentRayFlags);
        ++traceCount;
        return closest;
    }
#endif
    closest = tracePrimaryHit(origin, direction, segmentTMin, float(ADV_PRIMARY_MAX_DISTANCE), coneWidth, coneSpread,
                              ADV_TRACE_ROLE_PRIMARY, segmentMask, segmentRayFlags);
    ++traceCount;
    return closest;
}

HitPayload findBudgetedSegmentHit(vec3 origin,
                                  vec3 direction,
                                  float coneWidth,
                                  float coneSpread,
                                  uint medium,
                                  bool includeHand,
                                  uint reservedRayCount,
                                  inout uint rayBudgetUsed) {
    uint remainingBudget = remainingPathRayBudget(rayBudgetUsed);
    uint traceLimit = remainingBudget > reservedRayCount ? remainingBudget - reservedRayCount : 0u;
    uint traceCount;
    HitPayload hit = findSegmentHitWithTraceLimit(origin, direction, coneWidth, coneSpread, medium, false, includeHand,
                                                  traceLimit, traceCount);
    rayBudgetUsed += traceCount;
    return hit;
}

vec3 offsetRayAlongNormal(vec3 position, vec3 offsetNormal) {
    const float originThreshold = 1.0 / 32.0;
    const float floatScale = 1.0 / 65536.0;
    const float integerScale = 256.0;
    ivec3 integerOffset = ivec3(integerScale * offsetNormal);
    ivec3 positionBits = floatBitsToInt(position);
    ivec3 offsetBits = ivec3(position.x < 0.0 ? -integerOffset.x : integerOffset.x,
                             position.y < 0.0 ? -integerOffset.y : integerOffset.y,
                             position.z < 0.0 ? -integerOffset.z : integerOffset.z);
    vec3 integerPosition = intBitsToFloat(positionBits + offsetBits);
    return vec3(abs(position.x) < originThreshold ? position.x + floatScale * offsetNormal.x : integerPosition.x,
                abs(position.y) < originThreshold ? position.y + floatScale * offsetNormal.y : integerPosition.y,
                abs(position.z) < originThreshold ? position.z + floatScale * offsetNormal.z : integerPosition.z);
}

vec3 offsetRay(vec3 position, vec3 normal, vec3 direction) {
    float side = dot(direction, normal) >= 0.0 ? 1.0 : -1.0;
    return offsetRayAlongNormal(position, normal * side);
}

vec3 offsetParallaxExit(vec3 position, vec3 normal, vec3 direction) {
    float side = dot(direction, normal) >= 0.0 ? 1.0 : -1.0;
    return position + normal * (side * 0.0002);
}

#endif
