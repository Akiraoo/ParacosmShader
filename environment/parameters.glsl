#ifndef ADV_ENVIRONMENT_PARAMETERS_GLSL
#define ADV_ENVIRONMENT_PARAMETERS_GLSL

#ifndef ADV_SUN_RADIANCE
#    define ADV_SUN_RADIANCE 1.0, 1.0, 1.0
#endif
#ifndef ADV_MOON_RADIANCE
#    define ADV_MOON_RADIANCE 0.016, 0.02, 0.04
#endif
#ifndef ADV_SUN_INDIRECT_LIGHT_MULTIPLIER
#    define ADV_SUN_INDIRECT_LIGHT_MULTIPLIER 2.0
#endif
#ifndef ADV_MOON_INDIRECT_LIGHT_MULTIPLIER
#    define ADV_MOON_INDIRECT_LIGHT_MULTIPLIER 8.0
#endif
#ifndef ADV_INDIRECT_LIGHT_STRENGTH
#    define ADV_INDIRECT_LIGHT_STRENGTH 1.0
#endif
#ifndef ADV_SUNLIGHT_STRENGTH
#    define ADV_SUNLIGHT_STRENGTH 1.0
#endif
#ifndef ADV_ATMOSPHERE_HAZE
#    define ADV_ATMOSPHERE_HAZE 0.3
#endif
// Sunlit: fog beyond the 50-block froxel volume (lit by the sky only). 0 = off, 1 = outdoors only (fades out when
// the camera is enclosed, e.g. in caves), 2 = always (original behaviour).
#ifndef ADV_FAR_FOG_MODE
#    define ADV_FAR_FOG_MODE 0
#endif
#ifndef ADV_NETHER_FOG_ENABLED
#    define ADV_NETHER_FOG_ENABLED 1
#endif
#ifndef ADV_END_FOG_ENABLED
#    define ADV_END_FOG_ENABLED 0
#endif
#ifndef ADV_VOLUME_GOD_RAYS
#    define ADV_VOLUME_GOD_RAYS 1.0
#endif
// Sunlit: brightness of the sky as seen directly (and in refractions/clouds). The indirect sky that lights the
// scene already uses the x2 "sun indirect light multiplier"; the visible sky used x1, so it rendered as a dark
// navy dome above brightly lit terrain.
#ifndef ADV_SKY_BRIGHTNESS
#    define ADV_SKY_BRIGHTNESS 2.0
#endif
// Sunlit: overall daylight level (sun, sky and clouds together). Radiance's auto exposure is capped by
// "Exposure Ceiling" (+2.25 EV) and cannot reach its target in daylight with the original light levels, so
// daytime stayed ~1.5 EV darker than SEUS no matter what. Scaling daylight lifts the day without touching
// torches, caves or night.
#ifndef ADV_DAYLIGHT_INTENSITY
#    define ADV_DAYLIGHT_INTENSITY 3.0
#endif
#ifndef ADV_MOONLIGHT_INTENSITY
#    define ADV_MOONLIGHT_INTENSITY 1.0
#endif
#define ADV_SUN_RADIANCE_EFFECTIVE (vec3(ADV_SUN_RADIANCE) * max(float(ADV_DAYLIGHT_INTENSITY), 0.0))
#define ADV_MOON_RADIANCE_EFFECTIVE (vec3(ADV_MOON_RADIANCE) * max(float(ADV_MOONLIGHT_INTENSITY), 0.0))
#ifndef ADV_BASIC_RADIANCE
#    define ADV_BASIC_RADIANCE 0.0001
#endif
#ifndef ADV_ATMOSPHERE_RG
#    define ADV_ATMOSPHERE_RG 6360000.0
#endif
#ifndef ADV_ATMOSPHERE_RT
#    define ADV_ATMOSPHERE_RT 6460000.0
#endif
#ifndef ADV_ATMOSPHERE_HR
#    define ADV_ATMOSPHERE_HR 8000.0
#endif
#ifndef ADV_ATMOSPHERE_HM
#    define ADV_ATMOSPHERE_HM 1200.0
#endif
#ifndef ADV_ATMOSPHERE_BETA_R
#    define ADV_ATMOSPHERE_BETA_R vec3(0.000005802, 0.000013558, 0.0000331)
#endif
#ifndef ADV_ATMOSPHERE_BETA_M
#    define ADV_ATMOSPHERE_BETA_M vec3(0.000003996)
#endif
#ifndef ADV_ATMOSPHERE_OZONE_ABSORPTION
#    define ADV_ATMOSPHERE_OZONE_ABSORPTION vec3(0.000000650, 0.000001881, 0.000000085)
#endif
#ifndef ADV_ATMOSPHERE_MIE_G
#    define ADV_ATMOSPHERE_MIE_G 0.8
#endif
#ifndef ADV_ATMOSPHERE_MIN_VIEW_COS
#    define ADV_ATMOSPHERE_MIN_VIEW_COS 0.02
#endif

const float ADV_ENVIRONMENT_MAX_DISTANCE = 1000.0;
const vec3 ADV_ENVIRONMENT_AMBIENT = vec3(ADV_BASIC_RADIANCE);

#endif
