#version 460
#extension GL_GOOGLE_include_directive : require

// Sunlit post grade. Runs first in the post stage (on the tone-mapped image, before particles, text and the GUI).
//  * Colour grade: optional brightness, gentle S-curve contrast, sharpening and luminance-preserving
//    saturation/vibrance, for the crisp, vivid daylight look of SEUS PTGI.
//  * Underwater lens: when the camera is submerged the image gets a gentle animated refraction wobble and a
//    depth-aware blur (near objects stay readable, distant ones dissolve into the water).

#include "core/bindings.glsl"

#ifndef ADV_POST_UNDERWATER_ENABLED
#    define ADV_POST_UNDERWATER_ENABLED 1
#endif
#ifndef ADV_POST_UNDERWATER_BLUR
#    define ADV_POST_UNDERWATER_BLUR 1.0
#endif
#ifndef ADV_POST_UNDERWATER_DISTORTION
#    define ADV_POST_UNDERWATER_DISTORTION 1.0
#endif
#ifndef ADV_POST_BRIGHTNESS
#    define ADV_POST_BRIGHTNESS 1.0
#endif
#ifndef ADV_POST_SATURATION
#    define ADV_POST_SATURATION 1.05
#endif
#ifndef ADV_POST_VIBRANCE
#    define ADV_POST_VIBRANCE 0.2
#endif
#ifndef ADV_POST_CONTRAST
#    define ADV_POST_CONTRAST 0.25
#endif
#ifndef ADV_POST_SHARPEN
#    define ADV_POST_SHARPEN 0.3
#endif

layout(set = 3, binding = 1) uniform sampler2D postFirstHitDepth;
layout(set = 4, binding = ADV_POST_SCENE_COLOR_BINDING) uniform sampler2D postSceneColorTexture;
layout(set = 4, binding = ADV_CAMERA_MEDIUM_SAMPLED_BINDING) uniform sampler2D cameraMediumTexture;

layout(location = 0) out vec4 outColor;

const float ADV_UNDERWATER_TAU = 6.28318530717958648;
const float ADV_UNDERWATER_GOLDEN_ANGLE = 2.39996322972865332;
const int ADV_UNDERWATER_BLUR_TAPS = 16;

vec3 gradeSrgbToLinear(vec3 color) {
    color = clamp(color, vec3(0.0), vec3(1.0));
    return mix(color / 12.92, pow((color + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), color));
}

vec3 gradeLinearToSrgb(vec3 color) {
    color = clamp(color, vec3(0.0), vec3(1.0));
    return mix(color * 12.92, 1.055 * pow(color, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), color));
}

vec3 applyColorGrade(vec3 srgbColor) {
    vec3 color = gradeSrgbToLinear(srgbColor);

    // Brightness: slope g at black, exactly 1.0 at white, so highlights never clip harder than the tone mapper.
    float gain = max(float(ADV_POST_BRIGHTNESS), 0.0);
    color = gain * color / (vec3(1.0) + (gain - 1.0) * color);

    // Contrast: gentle S-curve on perceptual luminance (pivot at mid grey, black and white stay fixed), applied
    // as a luminance ratio so hues do not shift.
    float contrast = clamp(float(ADV_POST_CONTRAST), 0.0, 1.0);
    if (contrast > 1e-4) {
        float linearLuminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float perceptual = clamp(gradeLinearToSrgb(vec3(linearLuminance)).r, 0.0, 1.0);
        float rising = pow(perceptual, 1.35);
        float falling = pow(1.0 - perceptual, 1.35);
        float curved = mix(perceptual, rising / max(rising + falling, 1e-5), contrast);
        float targetLuminance = gradeSrgbToLinear(vec3(curved)).r;
        color *= targetLuminance / max(linearLuminance, 1e-5);
    }

    // Saturation + vibrance in perceptual (sRGB) space; vibrance lifts muted colours more than vivid ones.
    // (Doing this in linear space over-darkened the weakest channel, e.g. turned dirt orange.)
    vec3 perceptualColor = gradeLinearToSrgb(color);
    float luma = dot(perceptualColor, vec3(0.2126, 0.7152, 0.0722));
    float maximum = max(perceptualColor.r, max(perceptualColor.g, perceptualColor.b));
    float minimum = min(perceptualColor.r, min(perceptualColor.g, perceptualColor.b));
    float chroma = (maximum - minimum) / max(maximum, 1e-4);
    float saturation = max(float(ADV_POST_SATURATION), 0.0) +
                       max(float(ADV_POST_VIBRANCE), 0.0) * (1.0 - chroma) * (1.0 - chroma);
    vec3 saturated = vec3(luma) + (perceptualColor - vec3(luma)) * saturation;
    // Keep the result in gamut by scaling the chroma back instead of clipping channels (no hue shifts).
    float gamutScale = 1.0;
    float high = max(saturated.r, max(saturated.g, saturated.b));
    float low = min(saturated.r, min(saturated.g, saturated.b));
    if (high > 1.0) { gamutScale = min(gamutScale, (1.0 - luma) / max(high - luma, 1e-4)); }
    if (low < 0.0) { gamutScale = min(gamutScale, luma / max(luma - low, 1e-4)); }
    return clamp(vec3(luma) + (saturated - vec3(luma)) * gamutScale, vec3(0.0), vec3(1.0));
}

vec3 sampleScene(vec2 uv, vec2 texelSize) {
    uv = clamp(uv, texelSize * 0.5, vec2(1.0) - texelSize * 0.5);
    return textureLod(postSceneColorTexture, uv, 0.0).rgb;
}

float sampleDepth(vec2 uv) {
    float depthValue = textureLod(postFirstHitDepth, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).r;
    if (isnan(depthValue) || isinf(depthValue) || depthValue <= 0.0) { return 64.0; }
    return depthValue;
}

vec3 underwaterLens(ivec2 pixel, ivec2 resolution, vec4 medium) {
    vec2 texelSize = 1.0 / vec2(resolution);
    vec2 uv = (vec2(pixel) + 0.5) * texelSize;
    float aspect = float(resolution.x) / float(max(resolution.y, 1));
    float phase = ADV_UNDERWATER_TAU * fract(medium.g);

    // Refraction wobble: integer time multipliers keep the 8 s loop seamless.
    float distortion = max(float(ADV_POST_UNDERWATER_DISTORTION), 0.0) * 0.0022;
    vec2 wobble = vec2(sin(uv.y * 23.0 + phase * 5.0) + 0.5 * sin(uv.y * 41.0 - uv.x * 9.0 + phase * 7.0),
                       cos(uv.x * 19.0 * aspect + phase * 4.0) + 0.5 * cos(uv.x * 37.0 + uv.y * 11.0 - phase * 6.0));
    vec2 edgeFade = smoothstep(vec2(0.0), vec2(0.04), uv) * smoothstep(vec2(0.0), vec2(0.04), vec2(1.0) - uv);
    vec2 center = uv + wobble * distortion * vec2(1.0, aspect) * (edgeFade.x * edgeFade.y);

    float depthValue = sampleDepth(center);
    float blurStrength = max(float(ADV_POST_UNDERWATER_BLUR), 0.0);
    float radiusPixels = blurStrength * mix(0.75, 5.5, smoothstep(1.5, 28.0, depthValue)) *
                         (float(resolution.y) / 1080.0);
    if (radiusPixels < 0.35) { return sampleScene(center, texelSize); }

    vec3 accumulated = sampleScene(center, texelSize);
    float totalWeight = 1.0;
    for (int tap = 1; tap < ADV_UNDERWATER_BLUR_TAPS; ++tap) {
        float t = float(tap) / float(ADV_UNDERWATER_BLUR_TAPS - 1);
        float radius = sqrt(t) * radiusPixels;
        float angle = float(tap) * ADV_UNDERWATER_GOLDEN_ANGLE;
        vec2 offset = vec2(cos(angle), sin(angle)) * radius * texelSize;
        vec2 tapUv = center + offset;
        // Keep near foreground (hand, nearby blocks) from bleeding into the distant blur.
        float tapDepth = sampleDepth(tapUv);
        float depthWeight = clamp(tapDepth / max(depthValue, 1e-3), 0.25, 1.0);
        float weight = depthWeight * exp(-2.0 * t * t);
        accumulated += sampleScene(tapUv, texelSize) * weight;
        totalWeight += weight;
    }
    return accumulated / max(totalWeight, 1e-4);
}

void main() {
    ivec2 resolution = textureSize(postSceneColorTexture, 0);
    ivec2 pixel = clamp(ivec2(gl_FragCoord.xy), ivec2(0), resolution - ivec2(1));
    vec3 color = texelFetch(postSceneColorTexture, pixel, 0).rgb;
    bool isUnderwaterLens = false;
#if ADV_POST_UNDERWATER_ENABLED != 0
    vec4 medium = texelFetch(cameraMediumTexture, ivec2(0), 0);
    if (medium.r > 0.5 && !isnan(medium.r)) {
        color = underwaterLens(pixel, resolution, medium);
        isUnderwaterLens = true;
    }
#endif
    // Sharpening (contrast-adaptive, clamped to the local min/max so it cannot ring): restores the crisp texture
    // detail that the upscaler softens, a large part of the "dusty" look.
    float sharpen = clamp(float(ADV_POST_SHARPEN), 0.0, 1.0);
    if (!isUnderwaterLens && sharpen > 1e-4) {
        ivec2 maxPixel = resolution - ivec2(1);
        vec3 north = texelFetch(postSceneColorTexture, clamp(pixel + ivec2(0, 1), ivec2(0), maxPixel), 0).rgb;
        vec3 south = texelFetch(postSceneColorTexture, clamp(pixel - ivec2(0, 1), ivec2(0), maxPixel), 0).rgb;
        vec3 east = texelFetch(postSceneColorTexture, clamp(pixel + ivec2(1, 0), ivec2(0), maxPixel), 0).rgb;
        vec3 west = texelFetch(postSceneColorTexture, clamp(pixel - ivec2(1, 0), ivec2(0), maxPixel), 0).rgb;
        vec3 neighbourhoodMin = min(color, min(min(north, south), min(east, west)));
        vec3 neighbourhoodMax = max(color, max(max(north, south), max(east, west)));
        vec3 blurred = (north + south + east + west) * 0.25;
        vec3 sharpened = color + (color - blurred) * (sharpen * 1.5);
        color = clamp(sharpened, neighbourhoodMin, neighbourhoodMax);
    }
    outColor = vec4(applyColorGrade(color), 1.0);
}
