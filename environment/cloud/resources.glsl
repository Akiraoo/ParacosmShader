#ifndef ADV_ENVIRONMENT_CLOUD_RESOURCES_GLSL
#define ADV_ENVIRONMENT_CLOUD_RESOURCES_GLSL

#include "core/bindings.glsl"
#include "environment/celestial.glsl"
#include "environment/indirect_sky.glsl"

#ifndef ADV_CLOUD_MODE
#    define ADV_CLOUD_MODE 2u
#endif
#ifndef ADV_CLOUD_INDIRECT_ENABLED
#    define ADV_CLOUD_INDIRECT_ENABLED 1
#endif
#ifndef ADV_CLOUD_BOTTOM_HEIGHT
#    define ADV_CLOUD_BOTTOM_HEIGHT 200.0
#endif
#ifndef ADV_CLOUD_TOP_HEIGHT
#    define ADV_CLOUD_TOP_HEIGHT 480.0
#endif
#ifndef ADV_CLOUD_BASE_SCALE
#    define ADV_CLOUD_BASE_SCALE 0.22
#endif
#ifndef ADV_CLOUD_DETAIL_SCALE
#    define ADV_CLOUD_DETAIL_SCALE 0.60
#endif
#ifndef ADV_CLOUD_COVERAGE
#    define ADV_CLOUD_COVERAGE 0.45
#endif
#ifndef ADV_CLOUD_CLEAR_AMOUNT
#    define ADV_CLOUD_CLEAR_AMOUNT 1u
#endif
#ifndef ADV_CLOUD_DENSITY
#    define ADV_CLOUD_DENSITY 1.00
#endif
#ifndef ADV_CLOUD_VIEW_STEPS
#    define ADV_CLOUD_VIEW_STEPS 24
#endif
#ifndef ADV_CLOUD_LIGHT_STEPS
#    define ADV_CLOUD_LIGHT_STEPS 3
#endif
#ifndef ADV_CLOUD_SHADOWS_ENABLED
#    define ADV_CLOUD_SHADOWS_ENABLED 1
#endif
#ifndef ADV_CLOUD_AMBIENT_STEPS
#    define ADV_CLOUD_AMBIENT_STEPS 2
#endif
#ifndef ADV_CLOUD_AMBIENT_STRENGTH
#    define ADV_CLOUD_AMBIENT_STRENGTH 1.0
#endif
#ifndef ADV_CLOUD_POWDER_STRENGTH
#    define ADV_CLOUD_POWDER_STRENGTH 1.0
#endif
#ifndef ADV_CLOUD_WEATHER_SCALE
#    define ADV_CLOUD_WEATHER_SCALE 0.020
#endif
#ifndef ADV_CLOUD_SHADOW_STRENGTH
#    define ADV_CLOUD_SHADOW_STRENGTH 0.92
#endif
#ifndef ADV_CLOUD_SHADOW_SOFTNESS
#    define ADV_CLOUD_SHADOW_SOFTNESS 0.15
#endif
#ifndef ADV_CLOUD_INDIRECT_VIEW_STEPS
#    define ADV_CLOUD_INDIRECT_VIEW_STEPS 8
#endif
#ifndef ADV_CLOUD_INDIRECT_LIGHT_STEPS
#    define ADV_CLOUD_INDIRECT_LIGHT_STEPS 1
#endif
#ifndef ADV_CLOUD_INDIRECT_AMBIENT_STEPS
#    define ADV_CLOUD_INDIRECT_AMBIENT_STEPS 1
#endif
#ifndef ADV_CLOUD_REFLECTION_MAX_ROUGHNESS
#    define ADV_CLOUD_REFLECTION_MAX_ROUGHNESS 0.12
#endif
#ifndef ADV_CLOUD_JITTER_COORD
#    define ADV_CLOUD_JITTER_COORD vec2(gl_LaunchIDEXT.xy)
#endif
#ifndef ADV_CLOUD_DISTANCE_JITTER_SCALE
#    define ADV_CLOUD_DISTANCE_JITTER_SCALE 1.0
#endif
#ifndef ADV_CLOUD_BLUE_NOISE_TEMPORAL
#    define ADV_CLOUD_BLUE_NOISE_TEMPORAL 1
#endif
#define ADV_CLOUD_CLEAR_AMOUNT_FEW 0u
#define ADV_CLOUD_CLEAR_AMOUNT_MANY 2u

layout(set = 5, binding = ADV_CLOUD_SHAPE_NOISE_BINDING) uniform sampler3D cloudShapeNoiseTexture;
layout(set = 5, binding = ADV_CLOUD_DETAIL_NOISE_BINDING) uniform sampler3D cloudDetailNoiseTexture;
layout(set = 5, binding = ADV_CLOUD_BLUE_NOISE_BINDING) uniform sampler2D cloudBlueNoiseTexture;

struct CloudRadiance {
    vec3 radiance;
    float transmittance;
    float hitMask;
};

#endif