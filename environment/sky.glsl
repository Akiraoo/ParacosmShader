#ifndef ADV_ENVIRONMENT_SKY_GLSL
#define ADV_ENVIRONMENT_SKY_GLSL

#include "environment/parameters.glsl"

#ifndef ADV_CIRRUS_REFLECTIONS
#define ADV_CIRRUS_REFLECTIONS 1
#endif
#ifndef ADV_VANILLA_SUN
#define ADV_VANILLA_SUN 0
#endif

#include "environment/sunlit_state.glsl"
#include "environment/celestial.glsl"
#include "environment/indirect_sky.glsl"
#include "environment/night_sky.glsl"
#include "environment/cirrus.glsl"

bool findCelestialSphereIntersection(vec3 rayOrigin, vec3 rayDir, float radius, out float tNear, out float tFar) {
    float rayProjection = dot(rayOrigin, rayDir);
    float sphereOffset = dot(rayOrigin, rayOrigin) - radius * radius;
    float discriminant = rayProjection * rayProjection - sphereOffset;
    if (discriminant < 0.0) { return false; }
    discriminant = sqrt(discriminant);
    tNear = -rayProjection - discriminant;
    tFar = -rayProjection + discriminant;
    return true;
}

void buildCelestialBillboardBasis(vec3 normal, out vec3 tangent, out vec3 bitangent) {
    float normalSign = normal.z >= 0.0 ? 1.0 : -1.0;
    float basisScale = -1.0 / (normalSign + normal.z);
    float basisCrossTerm = normal.x * normal.y * basisScale;
    tangent =
        vec3(1.0 + normalSign * normal.x * normal.x * basisScale, normalSign * basisCrossTerm, -normalSign * normal.x);
    bitangent = vec3(basisCrossTerm, normalSign + normal.y * normal.y * basisScale, -normal.y);
    tangent = normalize(tangent);
    bitangent = normalize(bitangent);
}

vec4 sampleTextureBaseLod(sampler2D textureSampler, vec2 textureUv) {
    ivec2 texSize = textureSize(textureSampler, 0);
    if (texSize.x <= 0 || texSize.y <= 0) { return vec4(0.0); }
    vec2 halfTexel = 0.5 / vec2(texSize);
    vec2 clampedUv = clamp(textureUv, halfTexel, vec2(1.0) - halfTexel);
    return sampleTexture(textureSampler, clampedUv, 0.0, false);
}

vec4 sampleAtlasTileBaseLod(sampler2D textureSampler, vec2 tileUv, uvec2 atlasTileCount, uvec2 tile) {
    ivec2 texSize = textureSize(textureSampler, 0);
    if (texSize.x <= 0 || texSize.y <= 0) { return vec4(0.0); }

    vec2 invTileCount = 1.0 / vec2(atlasTileCount);
    vec2 tileMin = vec2(tile) * invTileCount;
    vec2 tileMax = tileMin + invTileCount;
    vec2 halfTexel = 0.5 / vec2(texSize);
    vec2 minUv = tileMin + halfTexel;
    vec2 maxUv = tileMax - halfTexel;
    vec2 atlasUv = mix(minUv, maxUv, clamp(tileUv, 0.0, 1.0));
    return sampleTexture(textureSampler, atlasUv, 0.0, false);
}

float calculateCelestialSquareAlignment(float tanHalf) {
    return inversesqrt(1.0 + 2.0 * tanHalf * tanHalf);
}

// Sunlit: 3D procedural solar sphere (or vanilla sun texture when ADV_VANILLA_SUN != 0).
#ifndef ADV_SUN_DISK_RADIUS
#    define ADV_SUN_DISK_RADIUS 0.022
#endif

vec4 evaluateSunBillboard(vec3 rayDir, bool detailedSurface) {
    vec3 sunDir = getCelestialSunDirection();
    float viewAlignment = dot(rayDir, sunDir);
    if (viewAlignment <= 0.0) { return vec4(0.0); }

#if ADV_VANILLA_SUN != 0
    float tanHalf = tan(0.09);
    float minSquareAlignment = calculateCelestialSquareAlignment(tanHalf);
    if (viewAlignment < minSquareAlignment) { return vec4(0.0); }

    vec3 right;
    vec3 up;
    buildCelestialBillboardBasis(sunDir, right, up);
    vec2 basisProjection = vec2(dot(rayDir, right), dot(rayDir, up));
    vec2 diskCoord = basisProjection / max(viewAlignment, 1e-4);
    vec2 absDiskCoord = abs(diskCoord);
    if (absDiskCoord.x > tanHalf || absDiskCoord.y > tanHalf) { return vec4(0.0); }

    vec2 textureUv = diskCoord / tanHalf * 0.5 + 0.5;
    vec4 rawTex = sampleTextureBaseLod(textures[nonuniformEXT(skyUBO.sunTextureID)], textureUv);
    vec4 cornerTex = sampleTextureBaseLod(textures[nonuniformEXT(skyUBO.sunTextureID)], vec2(0.0));

    // sun.png usually has a transparent background whose RGB is often white (alpha 0). The old code took the corner
    // texel's raw RGB as the "background floor" (~1.0 for such files), which subtracted the whole sun away and left
    // it invisible. Work with alpha-premultiplied colour instead: a transparent texel contributes nothing, whatever
    // RGB it stores, and an opaque dark background is still removed through the (premultiplied) corner floor.
    vec3 premulSun = rawTex.rgb * rawTex.a;
    vec3 premulCorner = cornerTex.rgb * cornerTex.a;
    // Capped at 0.5 so the floor can never erase the whole sun, whatever the texture looks like.
    float floorLevel = min(max(premulCorner.r, max(premulCorner.g, premulCorner.b)) + 0.03, 0.5);
    vec3 cleanRgb = max(premulSun - vec3(floorLevel), vec3(0.0)) / max(1.0 - floorLevel, 1e-3);

    float peak = max(cleanRgb.r, max(cleanRgb.g, cleanRgb.b));
    if (peak <= 1e-3) {
        // Very dim texture art (e.g. a resource pack sun): skip the floor removal instead of dropping the sun.
        cleanRgb = premulSun;
        peak = max(cleanRgb.r, max(cleanRgb.g, cleanRgb.b));
        if (peak <= 1e-3) { return vec4(0.0); }
    }

    vec3 linearSun = pow(cleanRgb, vec3(2.4));
    float isCore = smoothstep(0.55, 0.85, peak);
    vec3 sunTint = mix(vec3(1.0, 0.88, 0.65) * 0.22, vec3(1.0, 0.95, 0.82) * 2.2, isCore);
    // Alpha doubles as the "celestial pixel" mask (isCelestialBillboardVisible), so it covers the soft rim too.
    return vec4(linearSun * sunTint, smoothstep(0.02, 0.25, peak));
#else
    float tanRadius = tan(clamp(float(ADV_SUN_DISK_RADIUS), 0.002, 0.2));
    float coronaMaxRadius = tanRadius * 3.2;
    if (viewAlignment < inversesqrt(1.0 + coronaMaxRadius * coronaMaxRadius)) { return vec4(0.0); }

    vec3 right;
    vec3 up;
    buildCelestialBillboardBasis(sunDir, right, up);
    vec2 basisProjection = vec2(dot(rayDir, right), dot(rayDir, up));
    vec2 diskCoord = basisProjection / max(viewAlignment, 1e-4);
    vec2 uv = diskCoord / tanRadius;
    float r2 = dot(uv, uv);
    float radial = sqrt(r2);
    if (radial >= 3.2) { return vec4(0.0); }

    float days = sunlitContinuousDays();
    float spinAngle = days * 0.85;

    // Soft, cleaner warm-white solar corona around the 3D sphere (less yellow so it doesn't form a yellow ring).
    float coronaDist = max(radial - 0.99, 0.0);
    float coronaAngle = atan(uv.y, uv.x);
    float streamers = 0.88 + 0.12 * sin(coronaAngle * 7.0 + spinAngle * 1.5) *
                                 cos(coronaAngle * 11.0 - spinAngle * 0.9);
    float innerCorona = exp(-coronaDist * 11.0) * 0.36;
    float outerCorona = exp(-coronaDist * 2.6) * 0.08 * streamers;
    float coronaFade = 1.0 - smoothstep(1.0, 3.2, radial);
    vec3 coronaRadiance = vec3(1.0, 0.96, 0.88) * (innerCorona + outerCorona) * coronaFade;

    // Zoom-aware anti-aliasing width (stays ~1.5 pixels wide even when zoomed in with a spyglass/zoom mod).
    float projScaleY = abs(worldUBO.cameraProjMat[1][1]);
    float pixelAngle = 2.0 / max(projScaleY * 1080.0, 1.0);
    float edgeWidth = clamp(1.5 * pixelAngle / max(tanRadius, 1e-4), 0.0015, 0.035);
    float diskCoverage = 1.0 - smoothstep(1.0 - edgeWidth, 1.0 + edgeWidth, radial);
    if (diskCoverage <= 1e-4) {
        return vec4(coronaRadiance, 0.0);
    }

    // 3D unit sphere normal at the hit point (mu = cos(heliocentric angle): 1 at center, 0 at the 3D limb).
    float mu = sqrt(max(1.0 - min(r2, 1.0), 0.0));
    vec3 sphereNormal = vec3(uv * min(1.0, 1.0 / max(radial, 1e-4)) * sqrt(max(1.0 - mu * mu, 0.0)), mu);

    // Warm yellowish solar surface with smooth 3D limb darkening and without an overly yellow/orange border.
    vec3 limbDarkening = pow(vec3(max(mu, 1e-3)), vec3(0.42, 0.46, 0.52));
    vec3 surfaceColor = mix(vec3(1.0, 0.92, 0.78), vec3(1.0, 0.95, 0.82), pow(mu, 0.40));
    vec3 sphereRadiance = surfaceColor * limbDarkening;

    if (detailedSurface) {
        // Rotate the 3D point on the sphere around a slightly tilted solar axis.
        float c = cos(spinAngle);
        float s = sin(spinAngle);
        vec3 tilted = vec3(sphereNormal.x,
                           sphereNormal.y * 0.992 - sphereNormal.z * 0.126,
                           sphereNormal.y * 0.126 + sphereNormal.z * 0.992);
        vec3 pSphere = vec3(tilted.x * c + tilted.z * s, tilted.y, -tilted.x * s + tilted.z * c);
        vec3 flow = vec3(cos(spinAngle * 2.0), sin(spinAngle * 1.7), cos(spinAngle * 1.3)) * 0.35;

        // 3D domain-warped solar convection cells (photospheric granulation).
        vec3 warp = vec3(nsFbm3(pSphere * 5.5 + flow, 3),
                         nsFbm3(pSphere * 5.5 + flow + vec3(5.2, 1.3, -2.8), 3),
                         nsFbm3(pSphere * 5.5 - flow + vec3(-3.1, 4.7, 2.1), 3)) - 0.5;
        vec3 qSphere = pSphere + warp * 0.20;

        float superGranules = nsFbm3(qSphere * 4.5 + flow * 0.5, 3);
        float cellCoarse = 1.0 - abs(2.0 * nsNoise3(qSphere * 18.0 + flow * 1.4) - 1.0);
        float cellFine = 1.0 - abs(2.0 * nsNoise3(qSphere * 40.0 - flow * 2.1) - 1.0);
        float granulation = 0.65 * pow(cellCoarse, 0.60) + 0.35 * pow(cellFine, 0.70);

        // Bright magnetic faculae near the limb and subtle sunspots in active latitude bands.
        float faculaeMask = smoothstep(0.06, 0.35, mu) * (1.0 - smoothstep(0.45, 0.85, mu));
        float faculaeRidge = 1.0 - abs(2.0 * nsNoise3(qSphere * 12.5 + vec3(2.3, -1.7, 4.1)) - 1.0);
        float faculae = faculaeMask * pow(faculaeRidge, 3.5) * smoothstep(0.45, 0.72, superGranules);

        float spotBand = smoothstep(0.05, 0.15, abs(pSphere.y)) * (1.0 - smoothstep(0.34, 0.52, abs(pSphere.y)));
        float spotField = nsFbm3(qSphere * 9.0 + vec3(7.1, -3.4, 1.9), 3);
        float penumbra = spotBand * smoothstep(0.68, 0.76, spotField);
        float umbra = spotBand * smoothstep(0.75, 0.83, spotField);
        float spotFactor = 1.0 - 0.30 * penumbra - 0.35 * umbra;

        float surfaceModulation = (0.82 + 0.34 * granulation) * spotFactor + 0.26 * faculae;
        sphereRadiance *= surfaceModulation;
    }

    vec3 totalRadiance = sphereRadiance * (2.3 * diskCoverage) + coronaRadiance;
    return vec4(totalRadiance, diskCoverage);
#endif
}

vec4 evaluateSunBillboard(vec3 rayDir) {
    return evaluateSunBillboard(rayDir, false);
}

vec4 evaluateMoonBillboard(vec3 rayDir) {
    vec3 moonDir = getCelestialMoonDirection();
    float viewAlignment = dot(rayDir, moonDir);
    if (viewAlignment <= 0.0) { return vec4(0.0); }

    float tanHalf = tan(0.05);
    float minSquareAlignment = calculateCelestialSquareAlignment(tanHalf);
    if (viewAlignment < minSquareAlignment) { return vec4(0.0); }

    vec3 right;
    vec3 up;
    buildCelestialBillboardBasis(moonDir, right, up);
    vec2 basisProjection = vec2(dot(rayDir, right), dot(rayDir, up));
    vec2 diskCoord = basisProjection / max(viewAlignment, 1e-4);
    vec2 absDiskCoord = abs(diskCoord);
    if (absDiskCoord.x > tanHalf || absDiskCoord.y > tanHalf) { return vec4(0.0); }
    vec2 textureUv = diskCoord / tanHalf * 0.5 + 0.5;
    uvec2 atlasTileCount = uvec2(4u, 2u);
    uvec2 tile = uvec2(skyUBO.moonPhase % atlasTileCount.x, (skyUBO.moonPhase / atlasTileCount.x) % atlasTileCount.y);
    return sampleAtlasTileBaseLod(textures[nonuniformEXT(skyUBO.moonTextureID)], textureUv, atlasTileCount, tile);
}

vec3 calculateCelestialBillboardRadiance(vec3 rayDir, vec3 transmittance, bool indirectLighting) {
    vec2 radianceMultipliers = getCelestialRadianceMultipliers(indirectLighting);
    if (worldUBO.skyType != 1) { return vec3(0.0); }

    float rainVisibility = 1.0 - skyUBO.rainGradient;
    vec3 radiance = vec3(0.0);

    vec4 sunSample = evaluateSunBillboard(rayDir, !indirectLighting);
    if (max(sunSample.r, max(sunSample.g, sunSample.b)) > 1e-5) {
        float sunElevation = getCelestialSunDirection().y;
        vec3 sunsetTint = getCelestialAtmosphereTint(getCelestialSunsetTint(sunElevation),
                                                   max(float(worldUBO.cameraPos.y), 0.0) + 70.0);
        vec3 diskColor = transmittance * sunsetTint;
        float diskWarmth = 1.0 - smoothstep(0.04, 0.30, sunElevation);
        diskColor = mix(vec3(dot(diskColor, vec3(0.2126, 0.7152, 0.0722))), diskColor, diskWarmth);
        radiance += sunSample.rgb * ADV_SUN_RADIANCE_EFFECTIVE * radianceMultipliers.x * diskColor *
                    rainVisibility;
    }

    vec4 moonSample = evaluateMoonBillboard(rayDir);
    if (moonSample.a > 1e-4) {
        radiance += moonSample.rgb * ADV_MOON_RADIANCE * radianceMultipliers.y * max(transmittance, vec3(0.03)) *
                    rainVisibility;
    }

    return radiance;
}

bool isSkyVisible() {
    if (skyUBO.cameraSubmersionType == 0 || skyUBO.cameraSubmersionType == 2) { return false; }
    if (skyUBO.hasBlindnessOrDarkness > 0) { return false; }
    return worldUBO.skyType == 1;
}

vec3 sanitizeSkyRadiance(vec3 radiance) {
    if (any(isnan(radiance)) || any(isinf(radiance))) { return vec3(0.0); }
    return max(radiance, vec3(0.0));
}

vec3 normalizeSkyDirection(vec3 direction) {
    float lengthSquared = dot(direction, direction);
    if (lengthSquared <= 1e-8 || isnan(lengthSquared) || isinf(lengthSquared) || any(isnan(direction)) ||
        any(isinf(direction))) {
        return vec3(0.0, 1.0, 0.0);
    }
    return direction * inversesqrt(lengthSquared);
}

bool isCelestialBillboardVisible(vec3 rayDirection) {
    if (!isSkyVisible()) { return false; }

    vec3 rayDir = normalizeSkyDirection(rayDirection);
    float cameraHeight = worldUBO.cameraViewMatInv[3].y;
    vec3 planetPosition = vec3(0.0, ADV_ATMOSPHERE_RG + cameraHeight + 70.0, 0.0);
    float groundNear;
    float groundFar;
    bool isBlockedByGround =
        findCelestialSphereIntersection(planetPosition, rayDir, ADV_ATMOSPHERE_RG, groundNear, groundFar) &&
        groundFar > 1e-3;
    if (isBlockedByGround) { return false; }

    return evaluateSunBillboard(rayDir).a > 1e-4 || evaluateMoonBillboard(rayDir).a > 1e-4;
}

#ifndef ADV_END_SKY_BEAMS
#    define ADV_END_SKY_BEAMS 1.0
#endif
#ifndef ADV_END_SKY_STARS
#    define ADV_END_SKY_STARS 1.0
#endif

float endSkyHash(vec3 position) {
    position = fract(position * 0.3183099 + vec3(0.1, 0.2, 0.3));
    position *= 17.0;
    return fract(position.x * position.y * position.z * (position.x + position.y + position.z));
}

vec3 calculateEndSkyRadiance(vec3 rayDirection, bool indirectLighting) {
    vec3 fogColor = srgbToLinear(clamp(worldUBO.fogColor.rgb, vec3(0.0), vec3(1.0)));
    float level = max(dot(fogColor, vec3(0.2126, 0.7152, 0.0722)), 0.003);
    vec3 dir = normalizeSkyDirection(rayDirection);
    float elevation = dir.y;
    float time = worldUBO.gameTime * 6.28318530717958648 * 5.0;

    float horizonGlow = exp(-abs(elevation) * 3.5);
    vec3 zenithColor = vec3(0.05, 0.03, 0.11);
    vec3 horizonColor = vec3(0.62, 0.36, 0.72);
    vec3 voidColor = vec3(0.03, 0.02, 0.06);
    vec3 base = elevation >= 0.0 ? mix(zenithColor, horizonColor, horizonGlow) :
                                   mix(voidColor, horizonColor, exp(elevation * 6.0));

    float azimuth = atan(dir.z, dir.x);
    float sway = 0.035 * sin(elevation * 6.0 + azimuth * 2.0 + time * 9.0) +
                 0.015 * sin(elevation * 14.0 - azimuth * 3.0 - time * 14.0);
    float bent = azimuth + sway;
    float beams = pow(0.5 + 0.5 * sin(bent * 5.0 + 1.3 + time * 3.0), 6.0) +
                  0.7 * pow(0.5 + 0.5 * sin(bent * 11.0 - 0.7 - time * 5.0), 10.0) +
                  0.5 * pow(0.5 + 0.5 * sin(bent * 19.0 + 2.1 + time * 7.0), 16.0);
    beams *= 0.6 + 0.4 * sin(bent * 3.0 + time * 2.0);
    float heightProfile = elevation >= 0.0 ? exp(-elevation * 3.0) : exp(elevation * 5.0);
    vec3 beamColor = vec3(0.95, 0.55, 1.0);
    vec3 radiance = level * (base * 1.8 + beamColor * beams * heightProfile * 4.0 * max(float(ADV_END_SKY_BEAMS), 0.0));

    if (indirectLighting) { return radiance * 2.5; }

    if (ADV_END_SKY_STARS > 0.0 && elevation > -0.35) {
        const float cellScale = 140.0;
        vec3 cell = floor(dir * cellScale);
        float starSeed = endSkyHash(cell);
        if (starSeed > 0.985) {
            vec3 jitter = vec3(endSkyHash(cell + 1.7), endSkyHash(cell + 3.1), endSkyHash(cell + 5.3));
            vec3 starDirection = normalize((cell + 0.3 + 0.4 * jitter) / cellScale);
            float angularDistance = length(dir - starDirection);
            float star = exp(-pow(angularDistance / 0.0018, 2.0));
            float twinkle = 0.75 + 0.25 * sin(time * 600.0 + starSeed * 97.0);
            vec3 starColor = mix(vec3(1.0, 0.92, 1.0), vec3(0.78, 0.74, 1.0), fract(starSeed * 91.0));
            radiance += level * 40.0 * star * twinkle * starColor * float(ADV_END_SKY_STARS) *
                        smoothstep(-0.35, 0.05, elevation);
        }
    }
    return radiance;
}

#ifndef ADV_NIGHT_STARS
#    define ADV_NIGHT_STARS 1.0
#endif
#ifndef ADV_NIGHT_MILKY_WAY
#    define ADV_NIGHT_MILKY_WAY 1.0
#endif
#ifndef ADV_AURORA_MODE
#    define ADV_AURORA_MODE 1
#endif
#ifndef ADV_AURORA_STRENGTH
#    define ADV_AURORA_STRENGTH 1.0
#endif
#ifndef ADV_CIRRUS_AMOUNT
#    define ADV_CIRRUS_AMOUNT 0.45
#endif

float sunlitNightFactor() {
    return smoothstep(0.02, -0.14, getCelestialSunDirection().y) * (1.0 - clamp(skyUBO.rainGradient, 0.0, 1.0));
}

vec3 calculateAuroraRadiance(vec3 rayDir, float climate, bool indirectLighting) {
    if (ADV_AURORA_MODE == 0 || ADV_AURORA_STRENGTH <= 0.0) { return vec3(0.0); }
    float intensity = ADV_AURORA_MODE == 1 ? climate : 1.0;
    if (intensity <= 1e-3) { return vec3(0.0); }
    bool isUnderwater = skyUBO.cameraSubmersionType == 1u;
    float moonPhase = float(skyUBO.moonPhase % 8u);
    float seed = fract(moonPhase * 0.61803398875 + 0.137);
    float activity = 0.65 + 0.35 * nsHash12(vec2(moonPhase, 3.7));
    float dither = indirectLighting ? 0.5 : nsHash13(rayDir * 4096.0 + vec3(float(worldUBO.seed & 1023u)));
    int auroraSteps = indirectLighting ? 6 : (isUnderwater ? 10 : 24);
    bool auroraDetailed = !indirectLighting && !isUnderwater;
    vec3 aurora = evaluateAurora(rayDir, sunlitContinuousDays(), seed, climate, auroraSteps,
                                 auroraDetailed, dither);
    return aurora * (intensity * activity * ADV_AURORA_STRENGTH * (indirectLighting ? 0.12 : 1.0));
}

vec3 calculateNightSkyRadiance(vec3 rayDir, vec3 transmittance, float climate, bool indirectLighting) {
    float night = sunlitNightFactor();
    if (night <= 0.0 || rayDir.y <= -0.02) { return vec3(0.0); }
    vec3 radiance = vec3(0.0);
    if (!indirectLighting && (ADV_NIGHT_STARS > 0.0 || ADV_NIGHT_MILKY_WAY > 0.0)) {
        vec3 celestial = nightSkyCelestialDirection(rayDir, skyUBO.sunDirection);
        float timeSeconds = sunlitContinuousDays() * 1200.0;
        radiance += evaluateNightSkyCelestial(celestial, timeSeconds, max(float(ADV_NIGHT_STARS), 0.0),
                                              max(float(ADV_NIGHT_MILKY_WAY), 0.0)) *
                    transmittance;
    }
    radiance += calculateAuroraRadiance(rayDir, climate, indirectLighting) * sqrt(max(transmittance, vec3(0.0)));
    return radiance * (ADV_NIGHT_SKY_UNIT * night * smoothstep(-0.02, 0.05, rayDir.y));
}

vec4 calculateCirrus(vec3 rayDir, float cameraHeight, bool skipFineDetail) {
    float coverage = max(float(ADV_CIRRUS_AMOUNT), 0.0) * (1.0 - clamp(skyUBO.rainGradient, 0.0, 1.0));
    if (coverage <= 0.0 || rayDir.y <= 0.0) { return vec4(0.0); }
    float observerHeightKm = max(cameraHeight + 70.0, 0.0) * 0.001;
    float distanceKm = cirrusShellDistance(rayDir, observerHeightKm);
    if (distanceKm <= 0.0) { return vec4(0.0); }
    vec2 cameraKm = vec2(worldUBO.cameraPos.xz) * 0.001;
    float effectiveDistanceKm = skipFineDetail ? max(distanceKm, 140.0) : distanceKm;
    float opticalDepth = cirrusOpticalDepth(cameraKm + rayDir.xz * distanceKm, sunlitContinuousDays(), coverage,
                                            effectiveDistanceKm);
    float alpha = (1.0 - exp(-opticalDepth)) * smoothstep(0.0, 0.10, rayDir.y);
    if (alpha <= 1e-3) { return vec4(0.0); }

    vec3 cloudPlanetPosition = vec3(0.0, ADV_ATMOSPHERE_RG + max(cameraHeight, 0.0) + 70.0, 0.0) +
                               rayDir * (distanceKm * 1000.0);
    float cloudRadius = clamp(length(cloudPlanetPosition), ADV_ATMOSPHERE_RG, ADV_ATMOSPHERE_RT);
    vec3 cloudUp = cloudPlanetPosition / max(length(cloudPlanetPosition), 1.0);
    vec3 sunDir = getCelestialSunDirection();
    vec3 sunTransmittance = sampleAtmosphereLut(cloudRadius, dot(cloudUp, sunDir)) *
                            getCelestialAtmosphereTint(getCelestialSunsetTint(sunDir.y), cloudRadius - ADV_ATMOSPHERE_RG);
    vec3 sunLight = ADV_SUN_RADIANCE_EFFECTIVE * sunTransmittance * cirrusPhase(dot(rayDir, sunDir));
    vec3 moonLight = ADV_MOON_RADIANCE_EFFECTIVE * smoothstep(0.0, 0.12, -sunDir.y) *
                     sampleAtmosphereLut(cloudRadius, max(dot(cloudUp, -sunDir), 0.0)) * cirrusPhase(dot(rayDir, -sunDir));
    vec3 skyUp = texture(skyRadianceTexture, vec3(0.0, 1.0, 0.0)).rgb;
    vec3 skySide = texture(skyRadianceTexture, normalize(vec3(rayDir.x, 0.15, rayDir.z) + vec3(1e-4))).rgb;
    vec3 ambient = skyUp * 0.55 + skySide * 0.45;
    float twilight = (1.0 - smoothstep(-0.01, 0.08, sunDir.y)) * smoothstep(-0.16, -0.04, sunDir.y);
    ambient *= mix(vec3(1.0), vec3(1.22, 0.84, 1.02), twilight);
    vec3 cloudRadiance = (sunLight + moonLight) * (0.9 / (4.0 * PI)) + ambient * 0.9;
    return vec4(cloudRadiance, alpha);
}

vec3 calculateSkyRadiance(vec3 rayDirection, bool indirectLighting) {
    if (worldUBO.skyType == 2u && skyUBO.cameraSubmersionType != 0u &&
        skyUBO.cameraSubmersionType != 2u && skyUBO.hasBlindnessOrDarkness == 0u) {
        return sanitizeSkyRadiance(calculateEndSkyRadiance(rayDirection, indirectLighting));
    }
    if (!isSkyVisible()) { return vec3(0.0); }

    vec3 rayDir = normalizeSkyDirection(rayDirection);
    float rainGradient = skyUBO.rainGradient;
    vec4 cubeSample =
        indirectLighting ? texture(skyIndirectRadianceTexture, rayDir) : texture(skyRadianceTexture, rayDir);
    vec3 clearRadiance = cubeSample.rgb;
    float climate = isnan(cubeSample.a) ? 0.0 : clamp(cubeSample.a, 0.0, 1.0);
    vec3 rainyRadiance = getOvercastSkyRadiance(clearRadiance);
    vec3 radiance = mix(clearRadiance, rainyRadiance, rainGradient);

    float cameraHeight = worldUBO.cameraViewMatInv[3].y;
    vec3 planetPosition = vec3(0.0, ADV_ATMOSPHERE_RG + cameraHeight + 70.0, 0.0);
    float planetRadius = clamp(length(planetPosition), ADV_ATMOSPHERE_RG, ADV_ATMOSPHERE_RT);
    vec3 planetUp = planetPosition / max(planetRadius, 1e-6);
    float rayUpDot = clamp(dot(planetUp, rayDir), -1.0, 1.0);
    vec3 transmittance = sampleAtmosphereLut(planetRadius, rayUpDot);

    float groundNear;
    float groundFar;
    bool isBlockedByGround =
        findCelestialSphereIntersection(planetPosition, rayDir, ADV_ATMOSPHERE_RG, groundNear, groundFar) &&
        groundFar > 1e-3;
    if (!isBlockedByGround) {
        bool isUnderwater = skyUBO.cameraSubmersionType == 1u;
        vec3 space = calculateCelestialBillboardRadiance(rayDir, transmittance, indirectLighting);
        space += calculateNightSkyRadiance(rayDir, transmittance, climate, indirectLighting);

#if ADV_CIRRUS_REFLECTIONS != 0
        bool shouldDrawCirrus = !indirectLighting || !isUnderwater;
#else
        bool shouldDrawCirrus = !indirectLighting;
#endif

        if (shouldDrawCirrus) {
            vec4 cirrus = calculateCirrus(rayDir, cameraHeight, indirectLighting || isUnderwater);
            radiance = radiance * (1.0 - 0.3 * cirrus.a) + space * (1.0 - cirrus.a) + cirrus.rgb * cirrus.a;
        } else {
            radiance += space;
        }
    }

    return sanitizeSkyRadiance(radiance);
}

vec3 calculateSkyRadiance(vec3 rayDirection) {
    return calculateSkyRadiance(rayDirection, false);
}

vec3 calculateIndirectSkyRadiance(vec3 rayDirection) {
    return calculateSkyRadiance(rayDirection, true);
}

#endif
