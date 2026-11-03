#ifndef ADV_ENVIRONMENT_SUNLIT_STATE_GLSL
#define ADV_ENVIRONMENT_SUNLIT_STATE_GLSL

// Sunlit: small state kept across frames (one 48-byte buffer):
//  * climate estimate for the aurora (environment/climate.glsl);
//  * a continuous game clock: worldUBO.gameTime is the world time modulo one day (24000 ticks) and wraps to 0
//    once per game day, which made the volumetric clouds jump several kilometres at that moment;
//  * how open to the sky the camera is (0 deep in a cave, 1 outdoors), for the distant fog.
// The state lives as long as the render pipeline; it is rebuilt on a pipeline reload.

#include "core/bindings.glsl"

const uint ADV_SUNLIT_STATE_MAGIC = 0x5c11a7e6u;
const uint ADV_SUNLIT_STATE_SKY_KNOWN = 1u;
const uint ADV_SUNLIT_STATE_GROUND_KNOWN = 2u;

layout(std430, set = 5, binding = ADV_SUNLIT_STATE_BINDING) buffer SunlitStateBuffer {
    uint sunlitSnowSamples;
    uint sunlitGroundSamples;
    uint sunlitStateMagic;
    uint sunlitStateFlags;
    float sunlitSkyCold;
    float sunlitLatchX;
    float sunlitLatchZ;
    float sunlitGroundCold;
    float sunlitClimate;
    float sunlitLastGameTime;
    float sunlitDayCount;
    float sunlitSkyOpenness;
};

bool isSunlitStateValid() {
    return sunlitStateMagic == ADV_SUNLIT_STATE_MAGIC && !isnan(sunlitDayCount) && !isnan(sunlitLastGameTime) &&
           !isnan(sunlitSkyOpenness);
}

// Game time in days that keeps counting past the daily wrap of worldUBO.gameTime.
float sunlitContinuousDays() {
    float time = worldUBO.gameTime;
    if (!isSunlitStateValid()) { return time; }
    float days = sunlitDayCount;
    // gameTime already wrapped this frame but the compose pass has not counted the new day yet.
    if (time < sunlitLastGameTime - 0.5) { days += 1.0; }
    return days + time;
}

// Smoothed fraction of upward rays from the camera that reach the sky (1 when unknown).
float sunlitSkyOpennessValue() {
    return isSunlitStateValid() ? clamp(sunlitSkyOpenness, 0.0, 1.0) : 1.0;
}

#ifdef ADV_SUNLIT_STATE_UPDATE
// Called once per frame by a single invocation of the compose pass, before anything else uses the state.
void updateSunlitState() {
    float time = worldUBO.gameTime;
    if (!isSunlitStateValid() || isnan(sunlitClimate) || isnan(sunlitSkyCold) || isnan(sunlitGroundCold)) {
        sunlitSnowSamples = 0u;
        sunlitGroundSamples = 0u;
        sunlitStateFlags = 0u;
        sunlitSkyCold = 0.0;
        sunlitLatchX = 0.0;
        sunlitLatchZ = 0.0;
        sunlitGroundCold = 0.0;
        sunlitClimate = 0.0;
        sunlitLastGameTime = time;
        sunlitDayCount = 0.0;
        sunlitSkyOpenness = 1.0;
        sunlitStateMagic = ADV_SUNLIT_STATE_MAGIC;
        return;
    }
    if (time < sunlitLastGameTime - 0.5) {
        sunlitDayCount += 1.0;
    } else if (time > sunlitLastGameTime + 0.5) {
        // World time went back (another world was joined): keep counting from where we are.
        sunlitDayCount = max(sunlitDayCount - 1.0, 0.0);
    }
    sunlitLastGameTime = time;
}
#endif

#endif
