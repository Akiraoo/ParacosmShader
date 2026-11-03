#ifndef ADV_ENVIRONMENT_CIRRUS_GLSL
#define ADV_ENVIRONMENT_CIRRUS_GLSL

// Sunlit cirrus: a thin, high (9 km) layer of fibrous ice cloud above the normal clouds. Lit by the sun with a
// strong forward-scattering lobe (bright silver near the sun), glowing pink/orange around sunset - it stays sunlit
// for a while after the ground is in shadow - and faintly moonlit at night, veiling the stars. Written for this
// pack. Pure functions (no pack resources) so it can be previewed outside the game.

#include "environment/night_sky.glsl"

const float ADV_CIRRUS_HEIGHT_KM = 9.0;

// Distance (km) along a ray from an observer at `observerHeightKm` to the cirrus shell, or -1 if it is not reached.
float cirrusShellDistance(vec3 dir, float observerHeightKm) {
    const float planetRadius = 6360.0;
    float radius = planetRadius + observerHeightKm;
    float shellRadius = planetRadius + ADV_CIRRUS_HEIGHT_KM;
    if (observerHeightKm >= ADV_CIRRUS_HEIGHT_KM) { return -1.0; }
    float b = radius * dir.y;
    float discriminant = b * b - (radius * radius - shellRadius * shellRadius);
    if (discriminant < 0.0) { return -1.0; }
    return -b + sqrt(discriminant);
}

// Cloud optical depth at a point of the layer. positionKm: horizontal world position in km (wrapped by the caller),
// phase: 20-minute loop 0..1, coverage 0..1, distanceKm: from the observer (fine fibres fade out far away).
float cirrusOpticalDepth(vec2 positionKm, float phase, float coverage, float distanceKm) {
    if (coverage <= 0.0) { return 0.0; }
    // Slow, seamless evolution: the warp field drifts on a circle over the 20-minute game-time loop.
    vec2 drift = vec2(cos(NS_TAU * phase), sin(NS_TAU * phase)) * 2.5;
    vec2 wind = normalize(vec2(0.94, 0.34));
    vec2 across = vec2(-wind.y, wind.x);
    vec2 p = vec2(dot(positionKm, wind), dot(positionKm, across));
    p.x -= phase * 400.0;

    // Large patches of cirrus and clear sky.
    float patches = nsFbm2(p * 0.045 + drift * 0.08 + vec2(5.2, -1.3), 3);
    // Hooked, wind-stretched streaks: warp the streak coordinates with smooth noise.
    vec2 warp = vec2(nsFbm2(p * vec2(0.06, 0.12) + drift * 0.25, 3), nsFbm2(p * vec2(0.05, 0.10) - drift * 0.2 + 7.1, 3));
    vec2 streakCoord = p + (warp - 0.5) * vec2(10.0, 7.0);
    float far = smoothstep(25.0, 140.0, distanceKm);
    float streaks = nsFbm2(streakCoord * vec2(0.09, 0.55), 4);
    float fibres = far < 0.99 ? nsFbm2(streakCoord * vec2(0.25, 3.2) + vec2(1.7, 9.2), 3) : 0.5;
    fibres = mix(fibres, 0.5, far);

    float threshold = mix(0.70, 0.30, coverage);
    float shape = smoothstep(threshold, threshold + 0.22, patches * 0.55 + streaks * 0.65 - 0.10);
    float density = shape * (0.35 + 0.9 * fibres * fibres) * (0.55 + 0.45 * streaks);
    return density * 1.4;
}

// Ice-crystal phase function (normalised to 1 for isotropic): strong forward lobe plus a broad back lobe.
float cirrusPhase(float cosTheta) {
    float g1 = 0.80;
    float g2 = -0.20;
    float hg1 = (1.0 - g1 * g1) / pow(max(1.0 + g1 * g1 - 2.0 * g1 * cosTheta, 1e-4), 1.5);
    float hg2 = (1.0 - g2 * g2) / pow(max(1.0 + g2 * g2 - 2.0 * g2 * cosTheta, 1e-4), 1.5);
    return mix(hg2, hg1, 0.45);
}

#endif
