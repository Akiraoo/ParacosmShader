#ifndef ADV_ENVIRONMENT_NIGHT_SKY_GLSL
#define ADV_ENVIRONMENT_NIGHT_SKY_GLSL

// Sunlit night sky, written for this pack:
//  * stars with a magnitude and colour-temperature spread, densely sprinkled inside the nebula clouds, slight
//    twinkle;
//  * colourful nebula clouds (blue/cyan with golden regions, dark lanes, whiter cores) along a wandering galactic
//    band, plus a few distant galaxies;
//  * aurora: cyan-green curtains with vertical rays inside a violet glow, rippling and drifting, fixed to the world
//    (overhead in cold biomes, low over the northern horizon elsewhere).
// Stars, clouds and galaxies live on the celestial sphere and turn with the sun and moon.
// Only pure functions here (no pack resources), so the look can be previewed outside the game.

#ifndef ADV_NIGHT_SKY_UNIT
// Reference radiance: roughly the moonlit sky near the horizon in this pack.
#    define ADV_NIGHT_SKY_UNIT 0.001
#endif

const float NS_TAU = 6.28318530717958648;

// Integer hashing on the lattice: every lattice point gets exactly the same value whichever cell evaluates it.
// (The previous float "fract" hash could round differently for neighbouring cells on some GPUs, which showed up as
// straight seams through the cirrus.)
uint nsHashU(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

uint nsHashI2(ivec2 i) {
    uvec2 u = uvec2(i + ivec2(1073741824));
    return nsHashU(u.x * 0x9e3779b9u ^ nsHashU(u.y + 0x632be5abu));
}

uint nsHashI3(ivec3 i) {
    uvec3 u = uvec3(i + ivec3(1073741824));
    return nsHashU(u.x * 0x9e3779b9u ^ nsHashU(u.y * 0x85ebca6bu ^ nsHashU(u.z + 0xc2b2ae35u)));
}

float nsUnitFloat(uint h) {
    return float(h >> 8u) * (1.0 / 16777216.0);
}

float nsHash12(vec2 p) {
    return nsUnitFloat(nsHashI2(ivec2(floor(p))));
}

float nsHash13(vec3 p) {
    return nsUnitFloat(nsHashI3(ivec3(floor(p))));
}

vec3 nsHash33(vec3 p) {
    uint h = nsHashI3(ivec3(floor(p)));
    return vec3(nsUnitFloat(h), nsUnitFloat(nsHashU(h ^ 0x68e31da4u)), nsUnitFloat(nsHashU(h + 0xb5297a4du)));
}

float nsNoise2(vec2 p) {
    vec2 cell = floor(p);
    ivec2 i = ivec2(cell);
    vec2 f = p - cell;
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = nsUnitFloat(nsHashI2(i));
    float b = nsUnitFloat(nsHashI2(i + ivec2(1, 0)));
    float c = nsUnitFloat(nsHashI2(i + ivec2(0, 1)));
    float d = nsUnitFloat(nsHashI2(i + ivec2(1, 1)));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float nsNoise3(vec3 p) {
    vec3 cell = floor(p);
    ivec3 i = ivec3(cell);
    vec3 f = p - cell;
    vec3 u = f * f * (3.0 - 2.0 * f);
    float n000 = nsUnitFloat(nsHashI3(i));
    float n100 = nsUnitFloat(nsHashI3(i + ivec3(1, 0, 0)));
    float n010 = nsUnitFloat(nsHashI3(i + ivec3(0, 1, 0)));
    float n110 = nsUnitFloat(nsHashI3(i + ivec3(1, 1, 0)));
    float n001 = nsUnitFloat(nsHashI3(i + ivec3(0, 0, 1)));
    float n101 = nsUnitFloat(nsHashI3(i + ivec3(1, 0, 1)));
    float n011 = nsUnitFloat(nsHashI3(i + ivec3(0, 1, 1)));
    float n111 = nsUnitFloat(nsHashI3(i + ivec3(1, 1, 1)));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

float nsFbm3(vec3 p, int octaves) {
    float sum = 0.0;
    float amplitude = 0.5;
    float norm = 0.0;
    for (int octave = 0; octave < 6; ++octave) {
        if (octave >= octaves) { break; }
        sum += amplitude * nsNoise3(p);
        norm += amplitude;
        p = p * 2.03 + vec3(1.7, -3.1, 2.3);
        amplitude *= 0.5;
    }
    return sum / max(norm, 1e-4);
}

float nsFbm2(vec2 p, int octaves) {
    float sum = 0.0;
    float amplitude = 0.5;
    float norm = 0.0;
    for (int octave = 0; octave < 6; ++octave) {
        if (octave >= octaves) { break; }
        sum += amplitude * nsNoise2(p);
        norm += amplitude;
        p = mat2(1.6, 1.2, -1.2, 1.6) * p + vec2(3.7, -1.3);
        amplitude *= 0.5;
    }
    return sum / max(norm, 1e-4);
}

// ---------------------------------------------------------------------------------------------------------------
// Celestial frame. Minecraft turns the sky about the world Z axis and this pack tilts the sun path 10 degrees to
// the south; undo both so the returned direction is fixed to the stars.
vec3 nightSkyCelestialDirection(vec3 worldDirection, vec3 rawSunDirection) {
    const float tiltSin = 0.17364817766693033;
    const float tiltCos = 0.984807753012208;
    vec3 d = vec3(worldDirection.x, worldDirection.y * tiltCos + worldDirection.z * tiltSin,
                  -worldDirection.y * tiltSin + worldDirection.z * tiltCos);
    vec2 s = rawSunDirection.xy;
    float sLength = length(s);
    s = sLength > 1e-5 ? s / sLength : vec2(0.0, 1.0);
    return vec3(d.x * s.y - d.y * s.x, d.x * s.x + d.y * s.y, d.z);
}

// Galactic frame (celestial coordinates): pole, centre, and the third axis.
const vec3 NS_GALACTIC_POLE = vec3(0.62146, 0.22052, 0.75177);
const vec3 NS_GALACTIC_CENTER = vec3(-0.50094, -0.62594, 0.59772);
const vec3 NS_GALACTIC_SIDE = vec3(0.60237, -0.74805, -0.27853);

// Star colour from a 0..1 temperature: orange giants, yellow-white suns, white and blue-white hot stars.
vec3 nsStarColor(float temperature) {
    vec3 warm = vec3(1.0, 0.72, 0.46);
    vec3 sunLike = vec3(1.0, 0.93, 0.84);
    vec3 hot = vec3(0.70, 0.80, 1.0);
    return temperature < 0.5 ? mix(warm, sunLike, temperature * 2.0) : mix(sunLike, hot, temperature * 2.0 - 1.0);
}

// One layer of stars on a cube-mapped grid. Returns radiance in night units.
vec3 nsStarLayer(vec3 c, float cellsPerFace, float probability, float sigma, float brightnessPower, float seed,
                 float twinklePhase, float twinkleAmount) {
    vec3 a = abs(c);
    float major = max(a.x, max(a.y, a.z));
    vec2 uv;
    float face;
    if (a.x >= a.y && a.x >= a.z) {
        uv = c.yz / major;
        face = c.x > 0.0 ? 0.0 : 1.0;
    } else if (a.y >= a.z) {
        uv = c.xz / major;
        face = c.y > 0.0 ? 2.0 : 3.0;
    } else {
        uv = c.xy / major;
        face = c.z > 0.0 ? 4.0 : 5.0;
    }
    vec2 cell = floor((uv * 0.5 + 0.5) * cellsPerFace);
    vec3 cellId = vec3(cell, face * 131.0 + seed);
    vec3 random = nsHash33(cellId);
    if (random.x > probability) { return vec3(0.0); }

    vec2 starUv = ((cell + 0.25 + 0.5 * random.yz) / cellsPerFace) * 2.0 - 1.0;
    vec3 starDirection;
    if (face < 1.5) {
        starDirection = vec3(face < 0.5 ? 1.0 : -1.0, starUv.x, starUv.y);
    } else if (face < 3.5) {
        starDirection = vec3(starUv.x, face < 2.5 ? 1.0 : -1.0, starUv.y);
    } else {
        starDirection = vec3(starUv.x, starUv.y, face < 4.5 ? 1.0 : -1.0);
    }
    starDirection = normalize(starDirection);
    vec3 delta = c - starDirection;
    float distanceSquared = dot(delta, delta);
    float profile = exp(-distanceSquared / (sigma * sigma));
    if (profile < 1e-3) { return vec3(0.0); }

    float magnitude = pow(random.x / max(probability, 1e-5), brightnessPower);
    float extra = nsHash13(cellId + 17.3);
    float twinkle = 1.0 + twinkleAmount * sin(twinklePhase * (3.0 + 5.0 * extra) + extra * NS_TAU);
    return nsStarColor(fract(extra * 7.13)) * (magnitude * profile * twinkle);
}

// Nebula clouds along a wandering galactic band: billowy blue/cyan clouds with golden regions, dark dust lanes
// between them and whiter cores. Returns radiance in night units; `density` (0..~1.5) drives star clusters.
vec3 nsNebulaClouds(vec3 c, out float density) {
    float b = dot(c, NS_GALACTIC_POLE);
    float l = atan(dot(c, NS_GALACTIC_SIDE), dot(c, NS_GALACTIC_CENTER));
    float core = exp(-l * l / (2.0 * 0.7 * 0.7));

    // Domain warp gives the clouds their soft, swirling shapes.
    vec3 warp = vec3(nsFbm3(c * 2.1 + vec3(1.3, 7.1, -4.2), 3), nsFbm3(c * 2.1 + vec3(-6.4, 2.8, 9.3), 3),
                     nsFbm3(c * 2.1 + vec3(4.4, -8.1, 2.6), 3)) -
                0.5;
    vec3 q = c + warp * 0.42;
    float wanderingLatitude = b + 0.16 * (nsFbm3(c * 1.2 + vec3(11.0, -3.0, 6.0), 2) - 0.5);
    float width = 0.24 + 0.12 * core;
    float band = exp(-(wanderingLatitude * wanderingLatitude) / (width * width));

    float clouds = nsFbm3(q * 3.0 + vec3(2.0, -1.0, 5.0), 5);
    float billow = smoothstep(0.40, 0.70, clouds * (0.50 + 0.66 * band) + 0.06 * core);
    float detail = nsFbm3(q * 10.0 + vec3(-3.0, 4.0, 1.0), 3);
    density = billow * (0.45 + 1.0 * detail * detail * 1.6);

    // Dark lanes and gaps between the clouds.
    float dust = smoothstep(0.50, 0.70, nsFbm3(q * 6.0 + vec3(9.0, -2.0, 3.0), 4));
    density *= 1.0 - 0.80 * dust;

    // Mostly blue and cyan, with golden regions (stronger towards the galactic centre).
    float hue = nsFbm3(c * 1.5 + vec3(-7.7, 3.3, 5.5), 3);
    vec3 blue = vec3(0.26, 0.52, 1.0);
    vec3 cyan = vec3(0.42, 0.84, 1.0);
    vec3 gold = vec3(1.0, 0.62, 0.26);
    vec3 color = mix(blue, cyan, smoothstep(0.35, 0.85, detail));
    float goldWeight = smoothstep(0.55, 0.66, hue + 0.08 * core);
    color = mix(color, gold, goldWeight);
    // Bright cores bleach towards white.
    color = mix(color, vec3(0.92, 0.96, 1.0), smoothstep(0.75, 1.3, density) * 0.45);
    // A faint glow along the whole band so the clouds sit on something.
    vec3 glow = mix(vec3(0.30, 0.45, 0.80), vec3(0.80, 0.62, 0.42), core * 0.5) * band * 0.10;
    return color * density + glow;
}

// A distant galaxy: tilted elliptical blue-white glow with a bright core and faint spiral arms.
vec3 nsGalaxy(vec3 c, vec3 center, vec3 majorAxis, float size, float flattening, vec3 tint) {
    vec3 delta = c - center;
    if (dot(delta, delta) > size * size * 36.0) { return vec3(0.0); }
    vec3 minorAxis = normalize(cross(center, majorAxis));
    vec2 p = vec2(dot(delta, majorAxis), dot(delta, minorAxis)) / size;
    p.y /= flattening;
    float r = length(p);
    float angle = atan(p.y, p.x);
    float arms = 0.5 + 0.5 * sin(angle * 2.0 - log(max(r, 1e-3)) * 5.0);
    float mottling = 0.7 + 0.6 * nsNoise3(c * 400.0);
    float disk = exp(-r * 1.8) * (0.45 + 0.55 * arms) * mottling;
    float core = exp(-r * r * 30.0);
    return tint * (disk + core * 2.5);
}

// Stars, nebula clouds and galaxies for a celestial direction. Radiance in night units.
vec3 evaluateNightSkyCelestial(vec3 c, float timeSeconds, float starStrength, float milkyWayStrength) {
    vec3 radiance = vec3(0.0);
    float density = 0.0;
    if (milkyWayStrength > 0.0) {
        vec3 nebula = nsNebulaClouds(c, density);
        radiance += nebula * (28.0 * milkyWayStrength);
        vec3 galaxies = nsGalaxy(c, normalize(vec3(-0.30, 0.55, -0.78)), normalize(vec3(0.85, 0.10, -0.25)), 0.045,
                                 0.40, vec3(0.55, 0.75, 1.0));
        galaxies += nsGalaxy(c, normalize(vec3(0.72, -0.62, -0.30)), normalize(vec3(0.3, 0.6, 0.5)), 0.030, 0.75,
                             vec3(0.60, 0.80, 1.0));
        galaxies += nsGalaxy(c, normalize(vec3(-0.55, -0.35, 0.76)), normalize(vec3(0.75, -0.2, 0.45)), 0.022, 0.45,
                             vec3(1.0, 0.80, 0.60));
        radiance += galaxies * (9.0 * milkyWayStrength);
    } else {
        float b = dot(c, NS_GALACTIC_POLE);
        density = exp(-(b * b) / 0.04) * 0.5;
    }
    if (starStrength > 0.0) {
        float twinklePhase = timeSeconds;
        float cluster = clamp(density, 0.0, 1.2);
        // Dense sprinkles of small stars inside the nebula clouds, plus the general star field.
        vec3 stars = nsStarLayer(c, 300.0, 0.03 + 0.50 * cluster, 0.0017, 2.0, 0.0, twinklePhase, 0.25) * 22.0;
        stars += nsStarLayer(c, 110.0, 0.12, 0.0019, 4.0, 37.0, twinklePhase, 0.30) * 70.0;
        stars += nsStarLayer(c, 34.0, 0.16, 0.0024, 6.0, 71.0, twinklePhase, 0.20) * 260.0;
        radiance += stars * starStrength;
    }
    return radiance;
}

// ---------------------------------------------------------------------------------------------------------------
// Aurora. `phase` is the 20-minute game-time loop (0..1); every motion is periodic in it so the loop is seamless.
// `seed` changes from night to night. `overhead` 1 = curtains all over the sky (cold biome), 0 = only far north.

// Returns (curtain core, soft glow around it).
vec2 nsAuroraCurtain(vec2 p, float phase, float seed, float sharpness, float detail) {
    // p: kilometres east (x) / south (y) of the observer.
    vec2 q = p / 55.0 + vec2(seed * 13.7, seed * 5.3);
    vec2 slowDrift = vec2(cos(NS_TAU * 3.0 * phase), sin(NS_TAU * 3.0 * phase)) * 0.9;
    vec2 fastDrift = vec2(cos(NS_TAU * 37.0 * phase), sin(NS_TAU * 37.0 * phase)) * 0.18;

    // Curtains run roughly east-west; fold them with a smooth, slowly moving warp.
    float warp = 3.2 * nsNoise2(q * vec2(0.10, 0.22) + slowDrift) + 1.1 * nsNoise2(q * vec2(0.30, 0.55) - slowDrift);
    vec2 r = vec2(q.x * 0.11, q.y * 0.75 + warp);
    float ridge = 1.0 - abs(2.0 * nsNoise2(r + fastDrift * 0.5) - 1.0);
    float ridge2 = 1.0 - abs(2.0 * nsNoise2(r * vec2(1.7, 1.9) + vec2(4.1, -2.7) - fastDrift) - 1.0);
    float core = 1.5 * pow(ridge, sharpness) + 0.5 * pow(ridge2, sharpness * 1.4);
    float glow = 0.30 * pow(ridge, 5.0) + 0.12 * pow(ridge2, 6.0);

    // Patchy activity over hundreds of kilometres.
    float activity = smoothstep(0.32, 0.72, nsNoise2(p / 650.0 + slowDrift * 0.25 + vec2(seed * 3.1, -seed * 1.7)));

    // Vertical rays: brightness that varies along the curtain but not with height.
    float rays = 1.0;
    if (detail > 0.0) {
        float along = q.x * 3.5 + q.y * 0.6;
        float coarseRays = nsNoise2(vec2(along, seed * 3.0) + fastDrift * 2.0);
        float fineRays = nsNoise2(vec2(along * 4.3, seed * 7.0) - fastDrift * 3.0);
        rays = mix(1.0, (0.35 + 1.1 * coarseRays * coarseRays) * (0.6 + 0.55 * fineRays), detail);
    }
    return vec2(core * rays, glow) * activity;
}

// `dither` (0..1, different per pixel and frame) offsets the altitude samples; temporal accumulation then hides
// the sampling pattern. `detailed` adds the fine vertical rays. Radiance in night units.
vec3 evaluateAurora(vec3 dir, float phase, float seed, float overhead, int steps, bool detailed, float dither) {
    if (dir.y <= 0.002 || steps <= 0) { return vec3(0.0); }
    const float planetRadius = 6360.0;
    const float bottomHeight = 100.0;
    const float curtainHeight = 190.0;
    float mu = dir.y;
    float b = planetRadius * mu;
    float bottomDistance = -b + sqrt(b * b + 2.0 * planetRadius * bottomHeight + bottomHeight * bottomHeight);
    float topHeight = bottomHeight + curtainHeight;
    float topDistance = -b + sqrt(b * b + 2.0 * planetRadius * topHeight + topHeight * topHeight);
    // Far from the zenith the samples spread over many kilometres; soften the curtains there instead of aliasing.
    float spacing = (topDistance - bottomDistance) / float(steps);
    float lod = clamp((spacing - 4.0) / 30.0, 0.0, 1.0);
    float sharpness = mix(22.0, 9.0, lod);
    float detail = detailed ? 1.0 - lod * 0.5 : 0.0;
    float pathWeight = clamp((topDistance - bottomDistance) / curtainHeight, 1.0, 4.0);

    const vec3 green = vec3(0.14, 1.0, 0.62);
    const vec3 cyan = vec3(0.22, 0.95, 1.0);
    const vec3 violet = vec3(0.62, 0.30, 1.0);
    vec3 sum = vec3(0.0);
    for (int stepIndex = 0; stepIndex < 32; ++stepIndex) {
        if (stepIndex >= steps) { break; }
        float s = (float(stepIndex) + dither) / float(steps);
        float altitudeFraction = s * s;
        float height = bottomHeight + curtainHeight * altitudeFraction;
        float distance = -b + sqrt(b * b + 2.0 * planetRadius * height + height * height);
        vec2 p = dir.xz * distance;
        float north = smoothstep(-250.0, -700.0, p.y);
        float region = mix(north, 1.0, overhead);
        if (region <= 1e-3) { continue; }

        vec2 curtain = nsAuroraCurtain(p, phase, seed, sharpness, detail) * region;
        // Bright cyan-green curtains with a sharp lower edge, turning violet towards the top, inside a softer
        // violet-blue glow that reaches higher.
        float coreProfile = smoothstep(0.0, 0.03, altitudeFraction) * exp(-3.0 * altitudeFraction);
        float glowProfile = smoothstep(0.0, 0.12, altitudeFraction) * exp(-1.1 * altitudeFraction);
        vec3 coreColor = altitudeFraction < 0.25 ? mix(green, cyan, smoothstep(0.05, 0.25, altitudeFraction)) :
                                                   mix(cyan, violet, smoothstep(0.30, 0.80, altitudeFraction));
        vec3 glowColor = mix(vec3(0.18, 0.70, 0.85), violet, smoothstep(0.0, 0.45, altitudeFraction));
        sum += coreColor * (curtain.x * coreProfile) + glowColor * (curtain.y * glowProfile * 0.6);
    }
    return sum * (140.0 / float(steps)) * sqrt(pathWeight);
}

#endif
