#ifndef ADV_ENVIRONMENT_CLOUD_SHADE_GLSL
#define ADV_ENVIRONMENT_CLOUD_SHADE_GLSL

// Volumetric clouds (two-deck layer Y = 240..520, fast evaluation & long horizon range):
// - Lower/mid puffy cumulus deck with varied base heights + upper flaky altocumulus deck (Kappa-like depth).
// - Unified, branch-free ray-slab intersection: no zenith rings, no jumping cutoff at Y = bottom,
//   and full 14 km draw distance even when flying inside or above the cloud layer.
// - Distance fog & fade driven by actual cloud hit distance (`firstHitT`) rather than slab entry `t0`.

#include "environment/cloud/resources.glsl"
#include "environment/sunlit_state.glsl"

const double ADV_CLOUD_ORIGIN_PERIOD = 16384.0;
const float ADV_CLOUD_TILE = 16384.0 / 24.0;
const float ADV_CLOUD_SIGMA = 0.088;
const float ADV_CLOUD_MAX_DISTANCE = 14000.0;

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

// Default vertical range 240..520.
float chrCloudBottom() {
    float b = float(ADV_CLOUD_BOTTOM_HEIGHT);
    if (abs(b - 200.0) < 1.0 || abs(b - 300.0) < 1.0 || b < 100.0 || b > 800.0) { return 240.0; }
    return b;
}

float chrCloudTop() {
    float b = chrCloudBottom();
    float t = float(ADV_CLOUD_TOP_HEIGHT);
    if (abs(t - 480.0) < 1.0 || abs(t - 1000.0) < 1.0 || t < 300.0 || t > 1200.0 || t <= b + 140.0) {
        return max(520.0, b + 280.0);
    }
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

// Wind offset scaled to the cloud layer so angular drift speed across the sky stays natural.
vec3 chrCloudWindOffset(float t) {
    return vec3(t * (ADV_CLOUD_TILE / 120.0), 0.0, t * 1.05);
}

vec3 chrCloudWind(vec3 p) {
    return p - chrCloudWindOffset(chrCloudTime());
}

// Aperiodic 2D integer hash and value noise (only 4 hashes per call — very fast on ALU).
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

// Day-to-day cloudiness variation:
// Day 0: normal (1.00), Day 1: fewer clouds (0.82), Day 2: more clouds than Day 0 (1.18),
// with a subtle random variation on subsequent cycles.
float chrCloudDayTarget(int dayIndex) {
    int m = ((dayIndex % 3) + 3) % 3;
    float base = (m == 0) ? 1.00 : ((m == 1) ? 0.82 : 1.18);
    if (dayIndex >= 3) {
        float jitter = (chrCloudHash2(ivec2(dayIndex, 73)) - 0.5) * 0.10;
        base += jitter;
    }
    return clamp(base, 0.78, 1.22);
}

float chrCloudDailyFactor() {
    float days = sunlitContinuousDays();
    int d0 = int(floor(days));
    float f = fract(days);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(chrCloudDayTarget(d0), chrCloudDayTarget(d0 + 1), u);
}

float chrCloudClearAmountScale() {
    float preset = 1.0;
    if (ADV_CLOUD_CLEAR_AMOUNT == ADV_CLOUD_CLEAR_AMOUNT_FEW) {
        preset = 0.82;
    } else if (ADV_CLOUD_CLEAR_AMOUNT == ADV_CLOUD_CLEAR_AMOUNT_MANY) {
        preset = 1.22;
    }
    return preset * chrCloudDailyFactor();
}

// Two-deck 3D cloud base shape:
// - Lower/mid deck (h01 < 0.65): puffy cumulus clouds with varied base altitudes and convex rounded bottoms.
// - Upper deck (h01 >= 0.65): thinner, flakier altocumulus patches floating higher up (like Kappa).
// Uses only 2x 2D noises per sample with an immediate early-out before any 3D texture lookups.
float chrCloudBaseShapeAt(
    vec3 pWind, float h01, float rain, float clearCov, float baseScale, float detailWeight) {
    if (h01 <= 0.01 || h01 >= 0.99) { return 0.0; }

    float rainGrowth = rain * 0.5;
    float weatherScale = max(float(ADV_CLOUD_WEATHER_SCALE) / 0.020, 0.05);
    bool isUpperDeck = (h01 >= 0.65);

    vec2 p2 = pWind.xz * ((isUpperDeck ? 0.00245 : 0.00145) * weatherScale);
    if (isUpperDeck) {
        p2 += vec2(37.4, -23.8);
    } else {
        p2 += vec2(h01 - 0.30) * vec2(0.22, -0.16);
    }

    float macro1 = chrCloudNoise2D(p2 * 0.42 + vec2(1.3, 4.7));
    vec2 rotP2 = mat2(0.80, -0.60, 0.60, 0.80) * (p2 + (macro1 - 0.5) * 0.42);
    float pocketMed = chrCloudNoise2D(rotP2 * (isUpperDeck ? 2.60 : 2.05) - vec2(6.1, 2.8));

    float macro = smoothstep(0.18, 0.82, macro1 * 0.65 + pocketMed * 0.35);
    float fieldFair = pocketMed * 0.74 + macro1 * 0.26;
    float fieldStorm = max(fieldFair, pocketMed * 0.64 + macro1 * 0.36);
    float field3D = mix(fieldFair, fieldStorm, rainGrowth * 0.50);
    float combinedField = field3D * mix(0.66, mix(1.15, 1.26, rainGrowth), macro);

    float targetCov = clamp(clearCov * mix(1.0, 1.18, rainGrowth), 0.0, 0.70);
    if (isUpperDeck) {
        targetCov *= mix(0.76, 0.90, rainGrowth);
    }
    float threshold = clamp(0.95 - targetCov * 0.88, 0.24, 0.88);
    float rawCov = chrCloudSat(chrCloudRemap(combinedField, threshold, threshold + mix(0.34, 0.29, rainGrowth), 0.0, 1.0));
    if (rawCov <= 0.001) { return 0.0; }

    float localH;
    float boundaryFade;
    if (!isUpperDeck) {
        // Lower-mid cumulus deck: per-cluster altitude offset + convex upward curve at cloud edges
        // so cloud bottoms are rounded pillows rather than flat horizontal shelves.
        float altNoise = chrCloudSat(pocketMed * 0.45 + macro1 * 0.75 - 0.10) * (1.0 - rainGrowth * 0.5);
        float cloudBaseH = mix(0.02, 0.26, altNoise) + (1.0 - rawCov) * 0.12;
        float cloudSpanH = mix(0.18, 0.38, pow(rawCov, 0.60));
        float cloudTopH = min(cloudBaseH + cloudSpanH, 0.64);
        if (h01 <= cloudBaseH || h01 >= cloudTopH) { return 0.0; }

        localH = (h01 - cloudBaseH) / max(cloudTopH - cloudBaseH, 0.10);
        boundaryFade = smoothstep(0.0, 0.36, localH) * (1.0 - smoothstep(0.42, 1.0, localH));
    } else {
        // Upper altocumulus deck (0.65..0.98): thin, flaky patches high in the sky.
        float upperBaseH = mix(0.66, 0.74, macro1) + (1.0 - rawCov) * 0.04;
        float upperTopH = min(upperBaseH + mix(0.12, 0.23, rawCov), 0.98);
        if (h01 <= upperBaseH || h01 >= upperTopH) { return 0.0; }

        localH = (h01 - upperBaseH) / max(upperTopH - upperBaseH, 0.08);
        boundaryFade = smoothstep(0.0, 0.35, localH) * (1.0 - smoothstep(0.45, 1.0, localH));
    }

    float cov = pow(rawCov, mix(0.85, 0.75, rainGrowth)) * boundaryFade;
    if (cov <= 0.001) { return 0.0; }

    float freqMult = isUpperDeck ? 1.35 : 1.0;
    vec3 q1 = pWind / ADV_CLOUD_TILE * vec3(1.45 * baseScale * freqMult, 1.15 * baseScale, 1.45 * baseScale * freqMult);
    float s1 = textureLod(cloudShapeNoiseTexture, q1.xzy, 0.0).r;
    float shape = s1;
    if (detailWeight > 0.01) {
        vec2 rotXZ = mat2(0.7986, -0.6018, 0.6018, 0.7986) * pWind.xz;
        vec3 q2 = vec3(rotXZ.x, pWind.y + 53.0, rotXZ.y) / ADV_CLOUD_TILE *
                  vec3(2.80 * baseScale * freqMult, 2.20 * baseScale, 2.80 * baseScale * freqMult);
        float s2 = textureLod(cloudShapeNoiseTexture, q2.xzy, 0.0).r;
        shape = mix(s1, s2, 0.36 * (1.0 - rainGrowth * 0.35) * detailWeight) +
                (0.5 - s1) * (0.36 * (1.0 - rainGrowth * 0.35) * (1.0 - detailWeight)) * 0.25;
    }

    float base = chrCloudRemap(shape, 1.0 - cov * mix(0.86, 0.90, rainGrowth), 1.0, 0.0, 1.0);
    float edgeTaper = pow(cov, 0.68) * (isUpperDeck ? 0.60 : 1.0);
    return max(base * edgeTaper, 0.0);
}

// Cloud density for shadow, light-optical-depth and indirect rays (single 3D texture lookup).
float chrCloudDensityCheapAt(vec3 pWind, float h01, float rain, float clearCov, float baseScale) {
    float base = chrCloudBaseShapeAt(pWind, h01, rain, clearCov, baseScale, 0.0);
    if (base <= 0.0) { return 0.0; }
    float rainGrowth = rain * 0.5;
    float avgErosion = 0.50 * mix(0.35, 0.25, rainGrowth) * (1.0 - 0.60 * base);
    float d = chrCloudSat(chrCloudRemap(base, avgErosion, 1.0, 0.0, 1.0));
    return d * (0.45 + 0.55 * d) * mix(1.0, 1.25, rainGrowth);
}

// Full cloud density with smooth distance fade of 3D Worley detail erosion (no LOD seam).
float chrCloudDensityFullAt(vec3 pWind,
                            float h01,
                            float rain,
                            float clearCov,
                            float baseScale,
                            float detailScale,
                            float cloudTime,
                            float detailWeight) {
    float base = chrCloudBaseShapeAt(pWind, h01, rain, clearCov, baseScale, detailWeight);
    if (base <= 0.0) { return 0.0; }

    float rainGrowth = rain * 0.5;
    float detail = 0.5;
    if (detailWeight > 0.01 && base < 0.52) {
        vec3 dp = (pWind + vec3(cloudTime * 0.14, cloudTime * 0.18, -cloudTime * 0.11)) / ADV_CLOUD_TILE *
                  (9.2 * detailScale);
        float sampledDetail = textureLod(cloudDetailNoiseTexture, dp.xzy, 0.0).r;
        detail = mix(0.5, sampledDetail, detailWeight);
    }
    float erosion = detail * mix(0.35, 0.25, rainGrowth) * (1.0 - 0.60 * base);
    float d = chrCloudSat(chrCloudRemap(base, erosion, 1.0, 0.0, 1.0));
    return d * (0.45 + 0.55 * d) * mix(1.0, 1.25, rainGrowth);
}

float chrCloudHG(float g, float c) {
    float g2 = g * g;
    return (1.0 - g2) / (12.566371 * pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5));
}

// Dual-lobe Henyey-Greenstein phase function; softens the forward peak at low sun so sunset clouds don't blow out.
float chrCloudPhase(float cosTheta, float goldenHour) {
    float forwardG = mix(0.70, 0.52, goldenHour);
    float forwardPeak = chrCloudHG(forwardG, cosTheta);
    float forwardSoft = chrCloudHG(0.26, cosTheta);
    float backScatter = chrCloudHG(-0.20, cosTheta);
    return mix(backScatter, mix(forwardSoft, forwardPeak, mix(0.32, 0.20, goldenHour)), 0.68);
}

// Optical depth towards the sun/moon. Returns x = total optical depth, y = local near-surface density towards light.
vec2 chrCloudLightDepth(
    vec3 pWind, float h01, vec3 L, int lightSteps, float invThickness, float rain, float clearCov, float baseScale) {
    float od = 0.0;
    float nearOd = 0.0;
    float t = 0.0;
    float stepLen = mix(13.5, 8.5, clamp(abs(L.y) * 3.5, 0.0, 1.0));
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
        stepLen *= 1.75;
    }
    float sigma = ADV_CLOUD_SIGMA * max(float(ADV_CLOUD_DENSITY), 0.0) * mix(1.0, 1.45, rain);
    return vec2(od * sigma * 0.85, nearOd);
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

// Marches from a world position towards the sun/moon through the 3D cloud layer.
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

    int stepCount = clamp(steps, 2, 4);
    float dt = (t1 - t0) / float(stepCount);
    float od = 0.0;
    for (int i = 0; i < 4; ++i) {
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
    int shadowSteps = isUnderwater ? 2 : clamp(minimumSteps, 2, 3);
    float t = chrCloudShadowRayFromPoint(pAbs, lightDirection, shadowSteps);

    float softness = clamp(float(ADV_CLOUD_SHADOW_SOFTNESS), 0.0, 1.0);
    if (softness > 1e-4 && !isUnderwater && minimumSteps >= 6) {
        float radius = 20.0 * softness;
        float tPos = chrCloudShadowRayFromPoint(pAbs + vec3(radius, 0.0, radius * 0.5), lightDirection, 2);
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

    float bottom = chrCloudBottom();
    float top = chrCloudTop();
    float slabHeight = max(top - bottom, 1.0);
    vec3 o = rayOrigin + chrWrappedCamera(worldUBO.cameraPos.xyz);

    // Unified, continuous ray-slab intersection across all altitudes.
    float t0;
    float t1;
    if (abs(dir.y) < 1e-4) {
        if (o.y < bottom || o.y > top) { return result; }
        t0 = 0.0;
        t1 = ADV_CLOUD_MAX_DISTANCE;
    } else {
        float invDirY = 1.0 / dir.y;
        float tBottom = (bottom - o.y) * invDirY;
        float tTop = (top - o.y) * invDirY;
        t0 = max(min(tBottom, tTop), 0.0);
        t1 = min(max(tBottom, tTop), ADV_CLOUD_MAX_DISTANCE);
    }

    if (t1 <= t0 || t0 > ADV_CLOUD_MAX_DISTANCE) { return result; }
    // Allow rays near/inside the cloud layer to march all the way out to distant LOD clouds!
    float maxMarchSpan = mix(12000.0, 900.0, smoothstep(0.012, 0.35, abs(dir.y)));
    t1 = min(t1, min(t0 + maxMarchSpan, ADV_CLOUD_MAX_DISTANCE));

    vec3 sunDir = getCelestialSunDirection();
    vec3 moonDir = -sunDir;

    float rainGrade = clamp(skyUBO.rainGradient, 0.0, 1.0);
    float rain = chrCloudRain();
    vec2 multipliers = getCelestialRadianceMultipliers(indirectLighting);
    float visibleBoost = indirectLighting ? 1.0 : max(float(ADV_SKY_BRIGHTNESS), 0.0);

    // Smooth twilight handover between sunlight and moonlight.
    float goldenHour = (1.0 - smoothstep(0.04, 0.28, max(sunDir.y, 0.0))) * smoothstep(-0.08, 0.02, sunDir.y);
    float sunE = max(sunDir.y, 0.0);
    float horizonDim = pow(getCelestialSunHorizonDimming(sunE), 0.65);
    float sunWeight = smoothstep(-0.07, 0.05, sunDir.y) * mix(0.22, 1.0, horizonDim);
    vec3 sunTint = getCelestialSunlightColor(sunE);
    vec3 coralSunset = vec3(sunTint.r * 0.98, mix(sunTint.g, sunTint.r * 0.58, 0.40), max(sunTint.b, sunTint.r * 0.38));
    sunTint = mix(sunTint, coralSunset, goldenHour * 0.75);
    vec3 sunLight = ADV_SUN_RADIANCE_EFFECTIVE * sunTint * (0.62 * sunWeight) * multipliers.x * (0.5 * visibleBoost);

    float moonE = max(moonDir.y, 0.0);
    float moonWeight = smoothstep(0.03, 0.20, moonDir.y) * mix(0.55, 1.0, smoothstep(0.08, 0.45, moonE));
    vec3 moonLight = ADV_MOON_RADIANCE_EFFECTIVE * moonWeight * multipliers.y * 1.10;

    vec3 sun = (sunLight + moonLight) * mix(1.0, 0.28, rain);
    float sunLuma = dot(sunLight, vec3(0.2126, 0.7152, 0.0722));
    float moonLuma = dot(moonLight, vec3(0.2126, 0.7152, 0.0722));
    vec3 L = normalize(sunLuma >= moonLuma ? sunDir : moonDir);

    // Ambient sky light for the shadowed side and base of the clouds.
    vec3 clearZenith = indirectLighting ? textureLod(skyIndirectRadianceTexture, vec3(0.0, 1.0, 0.0), 0.0).rgb :
                                          textureLod(skyRadianceTexture, vec3(0.0, 1.0, 0.0), 0.0).rgb;
    vec3 sideDir = normalize(vec3(-L.z, 0.25, L.x));
    vec3 clearSide = indirectLighting ? textureLod(skyIndirectRadianceTexture, sideDir, 0.0).rgb :
                                        textureLod(skyRadianceTexture, sideDir, 0.0).rgb;

    vec3 zenith = mix(clearZenith, getOvercastSkyRadiance(clearZenith), rainGrade);
    vec3 horizon = mix(clearSide, getOvercastSkyRadiance(clearSide), rainGrade);

    float skyLuma = dot(zenith * 0.58 + horizon * 0.42, vec3(0.2126, 0.7152, 0.0722));
    vec3 dayShadow = mix(zenith * 0.60 + horizon * 0.40, vec3(skyLuma) * vec3(0.88, 0.94, 1.05), 0.50);
    vec3 twilightTint = vec3(0.82, 0.73, 1.05);
    vec3 duskShadow = mix(zenith * 0.75 + horizon * 0.25, vec3(skyLuma) * twilightTint, 0.58) * 0.90;
    vec3 fairShadowBase = mix(dayShadow, duskShadow, goldenHour);
    vec3 stormShadowBase = vec3(skyLuma) * vec3(0.50, 0.56, 0.67);
    vec3 shadowBase = mix(fairShadowBase, stormShadowBase, rain);

    float ambientStrength = max(float(ADV_CLOUD_AMBIENT_STRENGTH), 0.0);
    vec3 ambientTop = shadowBase * mix(1.00, 0.88, rain) * ambientStrength;
    vec3 ambientBottom = shadowBase * mix(0.70, 0.46, rain) * ambientStrength;

    float cosTheta = dot(dir, L);
    float phase = chrCloudPhase(cosTheta, goldenHour);
    float densityScale = max(float(ADV_CLOUD_DENSITY), 0.0);
    float powderStrength = clamp(float(ADV_CLOUD_POWDER_STRENGTH), 0.0, 1.0);
    float clearCov = clamp(float(ADV_CLOUD_COVERAGE) * chrCloudClearAmountScale(), 0.0, 1.0);
    float baseScale = max(float(ADV_CLOUD_BASE_SCALE) / 0.22, 0.05);
    float detailScale = max(float(ADV_CLOUD_DETAIL_SCALE) / 0.60, 0.05);
    float cloudTime = chrCloudTime();
    vec3 windShift = chrCloudWindOffset(cloudTime);
    float invThickness = 1.0 / slabHeight;

    vec3 cameraOrigin = worldUBO.cameraEffectedViewMatInv[3].xyz;
    vec3 originDelta = rayOrigin - cameraOrigin;
    bool isPrimaryCameraRay = !indirectLighting && dot(originDelta, originDelta) < 1.44;
    float jitter = indirectLighting ? 0.5 :
                   mix(0.5, sampleCloudStepJitter(17.0, isPrimaryCameraRay),
                       clamp(float(ADV_CLOUD_DISTANCE_JITTER_SCALE), 0.0, 1.0));

    bool isUnderwaterView = skyUBO.cameraSubmersionType == 1u;
    bool useCheapCloud = indirectLighting || isUnderwaterView;
    int maxSteps = isUnderwaterView ? min(viewStepCount, 6) : (indirectLighting ? min(viewStepCount, 8) : min(viewStepCount, 28));
    int steps = clamp(maxSteps, 6, 64);
    int effectiveLightSteps = (isUnderwaterView || indirectLighting) ? 1 : clamp(lightStepCount, 1, 3);

    float uniformDt = ((t1 - t0) / float(steps)) * mix(0.90, 1.04, abs(dir.y));
    // Perspective-scaled step size that starts compact near the camera (`16` blocks) and accelerates
    // fast enough in empty air (`16 + t * 0.135`) to reach all the way to 14 km even when `t0 = 0`!
    float initialStep = min(uniformDt * 1.30, max(16.0, t0 * 0.135 + 16.0));
    float t = t0 + jitter * initialStep;
    float T = 1.0;
    vec3 S = vec3(0.0);
    bool sunActive = max(sun.r, max(sun.g, sun.b)) > 1e-6;
    bool inCloud = false;
    float firstHitT = -1.0;
    int maxLoopIterations = useCheapCloud ? steps + 2 : steps + 18;

    for (int i = 0; i < 64; ++i) {
        if (t >= t1 || i >= maxLoopIterations) { break; }

        vec3 p = o + dir * t;
        float h01 = (p.y - bottom) * invThickness;
        vec3 pWind = p - windShift;

        float detailWeight = useCheapCloud ? 0.0 : (1.0 - smoothstep(1200.0, 3600.0, t));
        float stepEmpty = min(uniformDt * 1.32, max(18.0, t * 0.135 + 18.0));

        float d = chrCloudDensityFullAt(pWind, h01, rain, clearCov, baseScale, detailScale, cloudTime, detailWeight);
        if (d <= 0.002) {
            inCloud = false;
            t += stepEmpty;
            continue;
        }

        // Refine entry on the first hit after empty air so cloud silhouettes stay smooth with zero step stripes.
        if (!useCheapCloud && !inCloud && i > 0) {
            inCloud = true;
            float tBack = t - stepEmpty * 0.5;
            vec3 pMid = o + dir * tBack;
            float hMid = (pMid.y - bottom) * invThickness;
            float dMid = chrCloudDensityCheapAt(pMid - windShift, hMid, rain, clearCov, baseScale);
            t = (dMid > 0.002) ? (t - stepEmpty * 0.75) : (t - stepEmpty * 0.25);
            p = o + dir * t;
            h01 = (p.y - bottom) * invThickness;
            pWind = p - windShift;
            detailWeight = 1.0 - smoothstep(1200.0, 3600.0, t);
            d = chrCloudDensityFullAt(pWind, h01, rain, clearCov, baseScale, detailScale, cloudTime, detailWeight);
        } else {
            inCloud = true;
        }

        // Inside a cloud, use a finer step so the cloud's volume and edges are sampled accurately.
        float dt = min(uniformDt * 0.88, max(12.0, t * 0.050 + 12.0));
        if (d > 0.002) {
            result.hitMask = 1.0;
            if (firstHitT < 0.0) { firstHitT = t; }
            h01 = chrCloudSat(h01);

            int stepLightCount = (T < 0.18) ? 1 : effectiveLightSteps;
            vec2 lightData = sunActive ?
                                 chrCloudLightDepth(pWind, h01, L, stepLightCount, invThickness, rain, clearCov, baseScale) :
                                 vec2(0.0);
            float lightOd = lightData.x;
            float nearShadow = lightData.y;

            // Multi-scattering Beer-Lambert.
            float primaryScatter = exp(-lightOd);
            float multiScatterStrength = mix(0.40, 0.18, goldenHour * (1.0 - rain));
            float multiScatter = exp(-lightOd * mix(0.24, 0.32, goldenHour)) * mix(multiScatterStrength, 0.24, rain);
            vec3 scatterColor = vec3(primaryScatter) + vec3(multiScatter) * mix(vec3(1.0), vec3(1.02, 0.78, 0.88), goldenHour);

            // Gentle powder & sunward puff relief.
            float powder = 1.0 - exp(-d * 9.0) * 0.28;
            float billowRelief = exp(-nearShadow * 1.45);
            float directShape = mix(1.0, powder * mix(0.84, 1.18, billowRelief), powderStrength);
            vec3 lit = sun * scatterColor * phase * 12.566 * 0.36 * directShape;

            // Self-occlusion & shaded cloud base.
            float verticalAo = mix(mix(0.75, 0.48, rain), 1.0, smoothstep(0.04, 0.62, h01));
            float depthAo = exp(-d * mix(0.90, 1.40, rain)) * 0.28 + mix(0.72, 0.54, rain);
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

    // Use actual cloud hit distance (`firstHitT`) rather than slab entry `t0` so distance fog/fade
    // never changes when the camera flies up into or above the cloud layer!
    float cloudDist = (firstHitT >= 0.0) ? firstHitT : t0;
    float distFade = 1.0 - smoothstep(ADV_CLOUD_MAX_DISTANCE * 0.45, ADV_CLOUD_MAX_DISTANCE, cloudDist);
    float aerialMix = smoothstep(1000.0, ADV_CLOUD_MAX_DISTANCE * 0.75, cloudDist) * 0.65;
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