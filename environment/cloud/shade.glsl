#ifndef ADV_ENVIRONMENT_CLOUD_SHADE_GLSL
#define ADV_ENVIRONMENT_CLOUD_SHADE_GLSL

// Volumetric clouds (Photon-like lower & closer layer Y = 200..480, fast evaluation):
// - Closer to the ground and smaller in world units so their angular size and look stay the same while
//   requiring ~3.5x fewer raymarch operations.
// - Macro weather clusters create regions with many clouds and regions of clear sky.
// - In rain, clouds expand moderately in-place around their own centers and darken into storm clouds.
// - Cloud shadows use the exact same density curve and erosion threshold as visible clouds.

#include "environment/cloud/resources.glsl"
#include "environment/sunlit_state.glsl"

const double ADV_CLOUD_ORIGIN_PERIOD = 16384.0;
const float ADV_CLOUD_TILE = 16384.0 / 24.0;
const float ADV_CLOUD_SIGMA = 0.125;
const float ADV_CLOUD_MAX_DISTANCE = 4500.0;

float chrCloudSat(float x) {
    return clamp(x, 0.0, 1.0);
}

float chrCloudRemap(float v, float lo, float hi, float newLo, float newHi) {
    return newLo + (clamp(v, lo, hi) - lo) / max(hi - lo, 1e-5) * (newHi - newLo);
}

bool isCloudRadianceFinite(vec3 radiance) {
    return !any(isnan(radiance)) && !any(isinf(radiance));
}

// Camera position with X and Z wrapped in double precision into [-8192, 8192) so clouds stay smooth far from origin.
vec3 chrWrappedCamera(dvec3 c) {
    dvec2 xz = c.xz - floor((c.xz + ADV_CLOUD_ORIGIN_PERIOD * 0.5) / ADV_CLOUD_ORIGIN_PERIOD) * ADV_CLOUD_ORIGIN_PERIOD;
    return vec3(float(xz.x), float(c.y), float(xz.y));
}

// Default vertical range 200..480 (also remaps old saved defaults 300/1000 or 1800/7400).
float chrCloudBottom() {
    float b = float(ADV_CLOUD_BOTTOM_HEIGHT);
    if (abs(b - 300.0) < 1.0 || b < 100.0 || b > 800.0) { return 200.0; }
    return b;
}

float chrCloudTop() {
    float b = chrCloudBottom();
    float t = float(ADV_CLOUD_TOP_HEIGHT);
    if (abs(t - 1000.0) < 1.0 || t < 260.0 || t > 1200.0 || t <= b + 120.0) { return max(480.0, b + 280.0); }
    return t;
}

// Continuous game time in seconds (1200 s per Minecraft day) so clouds never jump when worldUBO.gameTime wraps.
float chrCloudTime() {
    return sunlitContinuousDays() * 1200.0;
}

// 0 = fair weather, 1 = storm clouds.
float chrCloudRain() {
    return smoothstep(0.0, 1.0, clamp(skyUBO.rainGradient, 0.0, 1.0));
}

// Wind offset scaled to the lower cloud layer so angular drift speed across the sky stays natural.
vec3 chrCloudWindOffset(float t) {
    return vec3(t * (ADV_CLOUD_TILE / 120.0), 0.0, t * 1.05);
}

vec3 chrCloudWind(vec3 p) {
    return p - chrCloudWindOffset(chrCloudTime());
}

float chrCloudClearAmountScale() {
    if (ADV_CLOUD_CLEAR_AMOUNT == ADV_CLOUD_CLEAR_AMOUNT_FEW) { return 0.78; }
    if (ADV_CLOUD_CLEAR_AMOUNT == ADV_CLOUD_CLEAR_AMOUNT_MANY) { return 1.25; }
    return 1.0;
}

// Aperiodic 2D & 3D integer hashes and value noise (no repeating grid).
float chrCloudHash2(ivec2 c) {
    uvec2 q = uvec2(c + ivec2(1073741824));
    uint h = q.x * 0x8da6b343u ^ q.y * 0xd8163841u ^ 0x2545f491u;
    h ^= h >> 16u;
    h *= 0x7feb352du;
    h ^= h >> 15u;
    h *= 0x846ca68bu;
    h ^= h >> 16u;
    return float(h >> 8u) * (1.0 / 16777216.0);
}

float chrCloudHash3(ivec3 c) {
    uvec3 q = uvec3(c + ivec3(1073741824));
    uint h = q.x * 0x8da6b343u ^ q.y * 0xd8163841u ^ q.z * 0xcb1ab31fu;
    h ^= h >> 16u;
    h *= 0x7feb352du;
    h ^= h >> 15u;
    h *= 0x846ca68bu;
    h ^= h >> 16u;
    return float(h >> 8u) * (1.0 / 16777216.0);
}

float chrCloudNoise2D(vec2 p) {
    vec2 i = floor(p);
    vec2 f = p - i;
    vec2 u = f * f * (3.0 - 2.0 * f);
    ivec2 c = ivec2(i);
    float a = chrCloudHash2(c);
    float b = chrCloudHash2(c + ivec2(1, 0));
    float d = chrCloudHash2(c + ivec2(0, 1));
    float e = chrCloudHash2(c + ivec2(1, 1));
    return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

float chrCloudNoise3D(vec3 p) {
    vec3 i = floor(p);
    vec3 f = p - i;
    vec3 u = f * f * (3.0 - 2.0 * f);
    ivec3 c = ivec3(i);
    float n000 = chrCloudHash3(c);
    float n100 = chrCloudHash3(c + ivec3(1, 0, 0));
    float n010 = chrCloudHash3(c + ivec3(0, 1, 0));
    float n110 = chrCloudHash3(c + ivec3(1, 1, 0));
    float n001 = chrCloudHash3(c + ivec3(0, 0, 1));
    float n101 = chrCloudHash3(c + ivec3(1, 0, 1));
    float n011 = chrCloudHash3(c + ivec3(0, 1, 1));
    float n111 = chrCloudHash3(c + ivec3(1, 1, 1));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

// Fast 3D cloud base shape. `highQuality` adds the second rotated 3D shape octave for primary view rays;
// shadow, light-depth, and indirect rays use a single 3D texture lookup for ~2.5x faster evaluation.
float chrCloudBaseShapeAt(vec3 pWind, float h01, float rain, float clearCov, float baseScale, bool highQuality) {
    if (h01 <= 0.0 || h01 >= 1.0) { return 0.0; }

    float boundaryFade = smoothstep(0.0, 0.08, h01) * (1.0 - smoothstep(0.90, 1.0, h01));
    if (boundaryFade <= 0.0) { return 0.0; }

    // 2x smaller volumetric expansion during rain.
    float rainGrowth = rain * 0.5;

    float weatherScale = max(float(ADV_CLOUD_WEATHER_SCALE) / 0.020, 0.05);
    vec2 p2 = pWind.xz * (0.00112 * weatherScale);

    // Macro sky regions + 3D pockets (streamlined to 2x 2D noises + 1x 3D noise).
    float macro1 = chrCloudNoise2D(p2 * 0.34 + vec2(1.3, 4.7));
    vec2 rotP2 = mat2(0.80, -0.60, 0.60, 0.80) * p2;
    float macro2 = chrCloudNoise2D(rotP2 * 0.75 - vec2(6.1, 2.8));
    float macro = smoothstep(0.18, 0.78, macro1 * 0.65 + macro2 * 0.35);

    vec3 w3 = vec3(p2.x * 2.0 + (macro2 - 0.5) * 0.8, pWind.y * 0.0075 + (macro1 - 0.5) * 0.9, p2.y * 2.0);
    float pocketMed = chrCloudNoise3D(w3 + vec3(5.2, 11.7, -3.4));
    float fieldFair = pocketMed * 0.72 + macro2 * 0.28;
    float fieldStorm = max(fieldFair, pocketMed * 0.65 + macro1 * 0.35);
    float field3D = mix(fieldFair, fieldStorm, rainGrowth * 0.50);

    float combinedField = field3D * mix(0.40, mix(1.24, 1.33, rainGrowth), macro);

    float targetCov = clamp(clearCov * mix(1.0, 1.18, rainGrowth), 0.0, 0.68);
    float threshold = clamp(1.0 - targetCov * 1.12, 0.18, 0.92);
    float cov = chrCloudSat(chrCloudRemap(combinedField, threshold, threshold + mix(0.40, 0.33, rainGrowth), 0.0, 1.0));
    cov = pow(cov, mix(1.0, 0.84, rainGrowth)) * boundaryFade;
    if (cov <= 0.001) { return 0.0; }

    vec3 q1 = pWind / ADV_CLOUD_TILE * vec3(1.35 * baseScale, 1.15 * baseScale, 1.35 * baseScale);
    float s1 = textureLod(cloudShapeNoiseTexture, q1.xzy, 0.0).r;
    float shape = s1;
    if (highQuality) {
        vec2 rotXZ = mat2(0.7986, -0.6018, 0.6018, 0.7986) * pWind.xz;
        vec3 q2 = vec3(rotXZ.x, pWind.y + 53.0, rotXZ.y) / ADV_CLOUD_TILE *
                  vec3(2.65 * baseScale, 2.20 * baseScale, 2.65 * baseScale);
        float s2 = textureLod(cloudShapeNoiseTexture, q2.xzy, 0.0).r;
        shape = mix(s1, s2, 0.38 * (1.0 - rainGrowth * 0.35));
    }

    float base = chrCloudRemap(shape, 1.0 - cov * mix(0.90, 0.93, rainGrowth), 1.0, 0.0, 1.0) * cov;
    return max(base, 0.0);
}

// Cloud density for shadow, light-optical-depth and indirect rays (single 3D texture lookup).
float chrCloudDensityCheapAt(vec3 pWind, float h01, float rain, float clearCov, float baseScale) {
    float base = chrCloudBaseShapeAt(pWind, h01, rain, clearCov, baseScale, false);
    if (base <= 0.0) { return 0.0; }
    float rainGrowth = rain * 0.5;
    float avgErosion = 0.50 * mix(0.42, 0.31, rainGrowth) * (1.0 - 0.55 * base);
    float d = chrCloudSat(chrCloudRemap(base, avgErosion, 1.0, 0.0, 1.0));
    return d * d * (3.0 - 2.0 * d) * mix(1.0, 1.25, rainGrowth);
}

// Full cloud density with 3D Worley detail erosion for primary view rays.
float chrCloudDensityFullAt(
    vec3 pWind, float h01, float rain, float clearCov, float baseScale, float detailScale, float cloudTime) {
    float base = chrCloudBaseShapeAt(pWind, h01, rain, clearCov, baseScale, true);
    if (base <= 0.0) { return 0.0; }

    float rainGrowth = rain * 0.5;
    // Only sample the 3D detail erosion texture in the outer shell of the cloud; deep inside the core it is already solid.
    float detail = 0.5;
    if (base < 0.48) {
        vec3 dp = (pWind + vec3(cloudTime * 0.15, cloudTime * 0.20, -cloudTime * 0.12)) / ADV_CLOUD_TILE *
                  (11.0 * detailScale);
        detail = textureLod(cloudDetailNoiseTexture, dp.xzy, 0.0).r;
    }
    float erosion = detail * mix(0.42, 0.31, rainGrowth) * (1.0 - 0.55 * base);
    float d = chrCloudSat(chrCloudRemap(base, erosion, 1.0, 0.0, 1.0));
    return d * d * (3.0 - 2.0 * d) * mix(1.0, 1.25, rainGrowth);
}

float chrCloudHG(float g, float c) {
    float g2 = g * g;
    return (1.0 - g2) / (12.566371 * pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5));
}

// Dual-lobe Henyey-Greenstein phase function with silver lining near the sun and soft back-scatter on puffs.
float chrCloudPhase(float cosTheta) {
    float forwardPeak = chrCloudHG(0.74, cosTheta);
    float forwardSoft = chrCloudHG(0.30, cosTheta);
    float backScatter = chrCloudHG(-0.20, cosTheta);
    return mix(backScatter, mix(forwardSoft, forwardPeak, 0.36), 0.70);
}

// Optical depth towards the sun/moon. Returns x = total optical depth, y = local near-surface density towards light.
vec2 chrCloudLightDepth(
    vec3 pWind, float h01, vec3 L, int lightSteps, float invThickness, float rain, float clearCov, float baseScale) {
    float od = 0.0;
    float nearOd = 0.0;
    float t = 0.0;
    float stepLen = 8.0;
    int steps = clamp(lightSteps, 1, 6);
    for (int i = 0; i < 6; ++i) {
        if (i >= steps) { break; }
        t += stepLen;
        float dist = t - 0.5 * stepLen;
        vec3 qWind = pWind + L * dist;
        float qH01 = h01 + (L.y * dist) * invThickness;
        if (qH01 <= 0.0 || qH01 >= 1.0) { break; }
        float d = chrCloudDensityCheapAt(qWind, qH01, rain, clearCov, baseScale);
        od += d * stepLen;
        if (i == 0) { nearOd = d; }
        stepLen *= 1.85;
    }
    float sigma = ADV_CLOUD_SIGMA * max(float(ADV_CLOUD_DENSITY), 0.0) * mix(1.0, 1.45, rain);
    return vec2(od * sigma * 1.15, nearOd);
}

float sampleCloudStepJitter(float jitterSalt, bool useTemporal) {
    ivec2 noiseSize = textureSize(cloudBlueNoiseTexture, 0);
    if (noiseSize.x <= 0 || noiseSize.y <= 0) { return 0.5; }
    ivec2 basePixel = ivec2(floor(ADV_CLOUD_JITTER_COORD));
    ivec2 jitterOffset = ivec2(int(jitterSalt * 19.0), int(jitterSalt * 47.0));
    ivec2 noisePixel = (basePixel + jitterOffset) % noiseSize;
    noisePixel = (noisePixel + noiseSize) % noiseSize;

    float blueNoise = texelFetch(cloudBlueNoiseTexture, noisePixel, 0).r;
    float temporalOffset = 0.0;
#if ADV_CLOUD_BLUE_NOISE_TEMPORAL != 0 && defined(MCVR_USE_DLSSRR) && MCVR_USE_DLSSRR != 0
    if (useTemporal) {
        temporalOffset = float(worldUBO.seed & 63u) * 0.61803398875;
    }
#endif
    return fract(blueNoise + temporalOffset + jitterSalt * 0.071);
}

// Marches from a world position towards the sun/moon through the 200..480 3D cloud layer.
float chrCloudShadowRayFromPoint(vec3 pAbs, vec3 L, int steps) {
    if (L.y < 0.03) { return 1.0; }
    float bottom = chrCloudBottom();
    float top = chrCloudTop();
    if (pAbs.y >= top) { return 1.0; }

    float t0 = max((bottom - pAbs.y) / L.y, 0.0);
    float t1 = (top - pAbs.y) / L.y;
    t1 = min(t1, t0 + 950.0);
    if (t1 <= t0) { return 1.0; }

    float invThickness = 1.0 / max(top - bottom, 1.0);
    float rain = chrCloudRain();
    float clearCov = clamp(float(ADV_CLOUD_COVERAGE) * chrCloudClearAmountScale(), 0.0, 1.0);
    float baseScale = max(float(ADV_CLOUD_BASE_SCALE) / 0.22, 0.05);
    vec3 startWind = chrCloudWind(pAbs);

    int stepCount = clamp(steps, 2, 5);
    float dt = (t1 - t0) / float(stepCount);
    float od = 0.0;
    for (int i = 0; i < 5; ++i) {
        if (i >= stepCount) { break; }
        float t = t0 + (float(i) + 0.5) * dt;
        vec3 qWind = startWind + L * t;
        float qH01 = (pAbs.y + L.y * t - bottom) * invThickness;
        od += chrCloudDensityCheapAt(qWind, qH01, rain, clearCov, baseScale) * dt;
    }
    float sigma = ADV_CLOUD_SIGMA * max(float(ADV_CLOUD_DENSITY), 0.0) * mix(1.0, 1.55, rain);
    return exp(-od * sigma);
}

float cloudLightVisibility(vec3 absoluteWorldPos, vec3 lightDirection, int minimumSteps, float multiScatterExtinction) {
    if (ADV_CLOUD_MODE != 2u || ADV_CLOUD_SHADOWS_ENABLED == 0) { return 1.0; }
    float strength = clamp(float(ADV_CLOUD_SHADOW_STRENGTH), 0.0, 1.0);
    if (strength <= 1e-4 || lightDirection.y < 0.03) { return 1.0; }

    vec3 relPos = absoluteWorldPos - vec3(worldUBO.cameraPos.xyz);
    vec3 pAbs = relPos + chrWrappedCamera(worldUBO.cameraPos.xyz);

    bool isUnderwater = skyUBO.cameraSubmersionType == 1u;
    int shadowSteps = isUnderwater ? 2 : clamp(minimumSteps, 3, 4);
    float t = chrCloudShadowRayFromPoint(pAbs, lightDirection, shadowSteps);

    float softness = clamp(float(ADV_CLOUD_SHADOW_SOFTNESS), 0.0, 1.0);
    if (softness > 1e-4 && !isUnderwater && minimumSteps >= 6) {
        float radius = 20.0 * softness;
        float tPos = chrCloudShadowRayFromPoint(pAbs + vec3(radius, 0.0, radius * 0.5), lightDirection, 3);
        t = mix(t, 0.5 * (t + tPos), softness);
    }

    t = max(t, 0.04);
    float horizonFade = smoothstep(0.03, 0.12, lightDirection.y);
    return mix(1.0, t, strength * horizonFade);
}

CloudRadiance integrateChromanceCloud(vec3 rayOrigin,
                                      vec3 rayDirection,
                                      vec3 skyBackgroundRadiance,
                                      int viewStepCount,
                                      int lightStepCount,
                                      bool indirectLighting) {
    CloudRadiance result;
    result.radiance = skyBackgroundRadiance;
    result.transmittance = 1.0;
    result.hitMask = 0.0;

    if (worldUBO.skyType != 1u || ADV_CLOUD_MODE != 2u) { return result; }

    float len2 = dot(rayDirection, rayDirection);
    if (len2 <= 1e-8 || any(isnan(rayDirection)) || any(isinf(rayDirection))) { return result; }
    vec3 dir = rayDirection * inversesqrt(len2);
    if (abs(dir.y) < 1e-4) { return result; }

    float bottom = chrCloudBottom();
    float top = chrCloudTop();
    vec3 o = rayOrigin + chrWrappedCamera(worldUBO.cameraPos.xyz);

    float t0 = (bottom - o.y) / dir.y;
    float t1 = (top - o.y) / dir.y;
    if (t0 > t1) {
        float tmp = t0;
        t0 = t1;
        t1 = tmp;
    }
    t0 = max(t0, 0.0);
    if (t1 <= t0 || t0 > ADV_CLOUD_MAX_DISTANCE) { return result; }
    t1 = min(t1, t0 + 950.0);

    vec3 sunDir = getCelestialSunDirection();
    vec3 moonDir = -sunDir;
    bool sunUp = sunDir.y >= -0.02;
    vec3 L = sunUp ? sunDir : moonDir;

    float rainGrade = clamp(skyUBO.rainGradient, 0.0, 1.0);
    float rain = chrCloudRain();
    vec2 multipliers = getCelestialRadianceMultipliers(indirectLighting);
    float visibleBoost = indirectLighting ? 1.0 : max(float(ADV_SKY_BRIGHTNESS), 0.0);

    // Direct sun/moon light on the sunlit side of the clouds.
    vec3 sun;
    float goldenHour = (1.0 - smoothstep(0.05, 0.32, max(sunDir.y, 0.0))) * smoothstep(-0.04, 0.02, sunDir.y);
    if (sunUp) {
        float e = max(sunDir.y, 0.0);
        float sunHeight = smoothstep(-0.02, 0.04, sunDir.y) * mix(0.75, 1.0, smoothstep(0.05, 0.45, e));
        vec3 sunTint = getCelestialSunlightColor(e);
        vec3 sunsetGold = vec3(1.38, 0.76, 0.32);
        sunTint = mix(sunTint, sunTint * sunsetGold, goldenHour * 0.60);
        sun = ADV_SUN_RADIANCE_EFFECTIVE * sunTint * (0.65 * sunHeight) * multipliers.x * (0.5 * visibleBoost);
    } else {
        float moonE = max(moonDir.y, 0.0);
        float moonHeight = smoothstep(-0.005, 0.06, moonDir.y) * mix(0.6, 1.0, smoothstep(0.05, 0.40, moonE));
        sun = ADV_MOON_RADIANCE_EFFECTIVE * moonHeight * multipliers.y * 1.15;
    }
    sun *= mix(1.0, 0.28, rain);

    // Ambient sky light for the shadowed side and base of the clouds.
    vec3 clearZenith = indirectLighting ? textureLod(skyIndirectRadianceTexture, vec3(0.0, 1.0, 0.0), 0.0).rgb :
                                          textureLod(skyRadianceTexture, vec3(0.0, 1.0, 0.0), 0.0).rgb;
    vec3 sideDir = normalize(vec3(-L.z, 0.22, L.x));
    vec3 clearSide = indirectLighting ? textureLod(skyIndirectRadianceTexture, sideDir, 0.0).rgb :
                                        textureLod(skyRadianceTexture, sideDir, 0.0).rgb;

    vec3 zenith = mix(clearZenith, getOvercastSkyRadiance(clearZenith), rainGrade);
    vec3 horizon = mix(clearSide, getOvercastSkyRadiance(clearSide), rainGrade);

    float skyLuma = dot(zenith * 0.55 + horizon * 0.45, vec3(0.2126, 0.7152, 0.0722));
    vec3 dayShadow = mix(zenith * 0.65 + horizon * 0.35, vec3(skyLuma) * vec3(0.84, 0.91, 1.06), 0.55);
    vec3 duskShadow = mix(zenith * 0.70 + horizon * 0.25, vec3(skyLuma) * vec3(0.72, 0.70, 0.92), 0.55) * 0.78;
    vec3 fairShadowBase = mix(dayShadow, duskShadow, goldenHour);
    vec3 stormShadowBase = vec3(skyLuma) * vec3(0.50, 0.56, 0.67);
    vec3 shadowBase = mix(fairShadowBase, stormShadowBase, rain);

    float ambientStrength = max(float(ADV_CLOUD_AMBIENT_STRENGTH), 0.0);
    vec3 ambientTop = shadowBase * mix(0.95, 0.88, rain) * ambientStrength;
    vec3 ambientBottom = shadowBase * mix(0.60, 0.46, rain) * ambientStrength;

    float cosTheta = dot(dir, L);
    float phase = chrCloudPhase(cosTheta);
    float densityScale = max(float(ADV_CLOUD_DENSITY), 0.0);
    float powderStrength = clamp(float(ADV_CLOUD_POWDER_STRENGTH), 0.0, 1.0);
    float clearCov = clamp(float(ADV_CLOUD_COVERAGE) * chrCloudClearAmountScale(), 0.0, 1.0);
    float baseScale = max(float(ADV_CLOUD_BASE_SCALE) / 0.22, 0.05);
    float detailScale = max(float(ADV_CLOUD_DETAIL_SCALE) / 0.60, 0.05);
    float cloudTime = chrCloudTime();
    vec3 windShift = chrCloudWindOffset(cloudTime);
    float invThickness = 1.0 / max(top - bottom, 1.0);

    vec3 cameraOrigin = worldUBO.cameraEffectedViewMatInv[3].xyz;
    vec3 originDelta = rayOrigin - cameraOrigin;
    bool isPrimaryCameraRay = !indirectLighting && dot(originDelta, originDelta) < 1.44;
    float jitter = indirectLighting ? 0.5 :
                   mix(0.5, sampleCloudStepJitter(17.0, isPrimaryCameraRay),
                       clamp(float(ADV_CLOUD_DISTANCE_JITTER_SCALE), 0.0, 1.0) * 0.75);

    bool isUnderwaterView = skyUBO.cameraSubmersionType == 1u;
    bool useCheapCloud = indirectLighting || isUnderwaterView;
    int maxSteps = isUnderwaterView ? min(viewStepCount, 6) : (indirectLighting ? min(viewStepCount, 8) : min(viewStepCount, 28));
    int steps = clamp(maxSteps, 6, 64);
    int effectiveLightSteps = (isUnderwaterView || indirectLighting) ? 1 : clamp(lightStepCount, 1, 3);
    float baseDt = ((t1 - t0) / float(steps)) * mix(0.88, 1.04, abs(dir.y));
    float t = t0 + jitter * baseDt;
    float T = 1.0;
    vec3 S = vec3(0.0);
    bool sunActive = max(sun.r, max(sun.g, sun.b)) > 1e-6;
    bool inCloud = false;
    int maxLoopIterations = useCheapCloud ? steps + 2 : steps + 10;

    for (int i = 0; i < 64; ++i) {
        if (t >= t1 || i >= maxLoopIterations) { break; }

        vec3 p = o + dir * t;
        float h01 = (p.y - bottom) * invThickness;
        vec3 pWind = p - windShift;

        float d;
        if (useCheapCloud) {
            d = chrCloudDensityCheapAt(pWind, h01, rain, clearCov, baseScale);
        } else {
            d = chrCloudDensityFullAt(pWind, h01, rain, clearCov, baseScale, detailScale, cloudTime);
        }
        if (d <= 0.002) {
            inCloud = false;
            t += baseDt * 1.65;
            continue;
        }

        // Refine entry on the first hit after empty air so cloud silhouettes stay smooth with fewer steps.
        if (!useCheapCloud && !inCloud && i > 0) {
            inCloud = true;
            t -= baseDt * 0.55;
            p = o + dir * t;
            h01 = (p.y - bottom) * invThickness;
            pWind = p - windShift;
            d = chrCloudDensityFullAt(pWind, h01, rain, clearCov, baseScale, detailScale, cloudTime);
        } else {
            inCloud = true;
        }

        float dt = baseDt * 0.85;
        if (d > 0.002) {
            result.hitMask = 1.0;
            h01 = chrCloudSat(h01);

            int stepLightCount = T < 0.15 ? 1 : effectiveLightSteps;
            vec2 lightData = sunActive ?
                                 chrCloudLightDepth(pWind, h01, L, stepLightCount, invThickness, rain, clearCov, baseScale) :
                                 vec2(0.0);
            float lightOd = lightData.x;
            float nearShadow = lightData.y;

            // Multi-scattering Beer-Lambert.
            float primaryScatter = exp(-lightOd);
            float multiScatter = exp(-lightOd * mix(0.22, 0.30, rain)) * mix(0.36, 0.26, rain);
            float beer = primaryScatter + multiScatter;

            // Gentle powder & sunward puff relief.
            float powder = 1.0 - exp(-d * 12.0) * 0.45;
            float billowRelief = exp(-nearShadow * 1.8);
            float directShape = mix(1.0, powder * mix(0.78, 1.22, billowRelief), powderStrength);
            vec3 lit = sun * beer * phase * 12.566 * 0.38 * directShape;

            // Self-occlusion.
            float verticalAo = mix(mix(0.68, 0.48, rain), 1.0, smoothstep(0.0, 0.65, h01));
            float depthAo = exp(-d * mix(1.1, 1.45, rain)) * 0.35 + mix(0.65, 0.54, rain);
            vec3 ambient = mix(ambientBottom, ambientTop, h01) * verticalAo * depthAo;

            vec3 src = lit + ambient;
            float sigma = d * ADV_CLOUD_SIGMA * densityScale * mix(1.0, 1.55, rain);
            float stepT = exp(-sigma * dt);
            S += T * src * (1.0 - stepT);
            T *= stepT;
            if (T < 0.02) {
                T = 0.0;
                break;
            }
        }
        t += dt;
    }

    // Distance atmospheric perspective & horizon fade so far clouds blend softly into the horizon haze.
    float distFade = 1.0 - smoothstep(ADV_CLOUD_MAX_DISTANCE * 0.30, ADV_CLOUD_MAX_DISTANCE, t0);
    float aerialMix = smoothstep(500.0, ADV_CLOUD_MAX_DISTANCE * 0.75, t0) * 0.55;
    S = mix(S, skyBackgroundRadiance * (1.0 - T), aerialMix);

    vec3 scatter = S * distFade;
    float transmittance = mix(1.0, T, distFade);

    // When a cloud blocks the sun disk, soften the sharp sun billboard behind the cloud so it doesn't burn through.
    float bgTransmit = transmittance;
    if (cosTheta > 0.995) {
        bgTransmit = transmittance * transmittance;
    }

    result.transmittance = transmittance;
    result.radiance = skyBackgroundRadiance * bgTransmit + scatter;
    return result;
}

CloudRadiance shadeCloud(vec3 rayOrigin,
                         vec3 rayDirection,
                         vec3 skyBackgroundRadiance,
                         int viewStepCount,
                         int lightStepCount,
                         int ambientStepCount,
                         bool indirectLighting) {
    CloudRadiance cloudRadiance;
    cloudRadiance.radiance = max(skyBackgroundRadiance, vec3(0.0));
    cloudRadiance.transmittance = 1.0;
    cloudRadiance.hitMask = 0.0;
    if (ADV_CLOUD_MODE != 2u) { return cloudRadiance; }

    cloudRadiance = integrateChromanceCloud(rayOrigin, rayDirection, cloudRadiance.radiance, max(viewStepCount, 1),
                                            max(lightStepCount, 1), indirectLighting);
    if (!isCloudRadianceFinite(cloudRadiance.radiance) || isnan(cloudRadiance.transmittance) ||
        isinf(cloudRadiance.transmittance)) {
        cloudRadiance.radiance = max(skyBackgroundRadiance, vec3(0.0));
        cloudRadiance.transmittance = 1.0;
        cloudRadiance.hitMask = 0.0;
    } else {
        cloudRadiance.radiance = max(cloudRadiance.radiance, vec3(0.0));
        cloudRadiance.transmittance = clamp(cloudRadiance.transmittance, 0.0, 1.0);
    }
    return cloudRadiance;
}

vec3 shadeIndirectCloud(vec3 rayOrigin, vec3 rayDirection, vec3 skyBackgroundRadiance) {
    if (ADV_CLOUD_INDIRECT_ENABLED == 0) { return max(skyBackgroundRadiance, vec3(0.0)); }
    return shadeCloud(rayOrigin, rayDirection, skyBackgroundRadiance, ADV_CLOUD_INDIRECT_VIEW_STEPS,
                      ADV_CLOUD_INDIRECT_LIGHT_STEPS, ADV_CLOUD_INDIRECT_AMBIENT_STEPS, true)
        .radiance;
}

#endif