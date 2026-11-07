#ifndef ADV_LIGHTING_EMISSION_DEBUG_GLSL
#define ADV_LIGHTING_EMISSION_DEBUG_GLSL

// Sunlit: DEBUG view of the emission data Radiance hands to the shader. Off by default (0): with 0 nothing in this
// file is compiled and the picture is untouched.
//
// When on, every block (chunk geometry) seen directly by the camera is painted a flat, very bright colour that
// encodes one quantity, and the block's own lighting is dimmed so the world stays recognisable. Entities, sky, water
// and everything seen only through reflections are left alone.
//
//   1  vertex emission        (what Radiance writes into the block vertices, 0..1)
//   2  vertex emission shifted (same, bins moved by half a step: together with 1 this gives twice the resolution)
//   3  texture emission       (alpha of the specular map: from the PBR pack, or Radiance's built-in one without a pack)
//   4  flags                  (R = full 1x1 face, G = a specular map is bound, B = opaque block)
//
// Modes 1-3 colour the value in 8 bins of 1/8 (bin = floor(value * 8), mode 2: floor(value * 8 + 0.5)):
//   bin 0 black   1 red   2 yellow   3 green   4 cyan   5 blue   6 magenta   7 white (value >= 0.875)
#ifndef ADV_DEBUG_EMISSION
#    define ADV_DEBUG_EMISSION 0
#endif

#if ADV_DEBUG_EMISSION != 0

// Large on purpose: whatever the auto exposure does, each colour channel stays clearly "on" or "off".
const float SUNLIT_DEBUG_BRIGHTNESS = 32.0;
// Block lighting is kept at this fraction so unlit terrain stays visible next to the coloured blocks.
const float SUNLIT_DEBUG_ALBEDO_SCALE = 0.15;

vec3 sunlitDebugPalette(float value, float binOffset) {
    int bin = clamp(int(floor(value * 8.0 + binOffset)), 0, 7);
    if (bin == 1) { return vec3(1.0, 0.0, 0.0); }
    if (bin == 2) { return vec3(1.0, 1.0, 0.0); }
    if (bin == 3) { return vec3(0.0, 1.0, 0.0); }
    if (bin == 4) { return vec3(0.0, 1.0, 1.0); }
    if (bin == 5) { return vec3(0.0, 0.0, 1.0); }
    if (bin == 6) { return vec3(1.0, 0.0, 1.0); }
    if (bin == 7) { return vec3(1.0, 1.0, 1.0); }
    return vec3(0.0);
}

vec3 sunlitDebugEmissionColor(
    float vertexEmission, float textureEmission, float faceArea, bool hasSpecularMap, uint alphaMode) {
#    if ADV_DEBUG_EMISSION == 1
    vec3 color = sunlitDebugPalette(vertexEmission, 0.0);
#    elif ADV_DEBUG_EMISSION == 2
    vec3 color = sunlitDebugPalette(vertexEmission, 0.5);
#    elif ADV_DEBUG_EMISSION == 3
    vec3 color = sunlitDebugPalette(textureEmission, 0.0);
#    else
    vec3 color = vec3(faceArea >= 0.40 ? 1.0 : 0.0, hasSpecularMap ? 1.0 : 0.0, alphaMode == 0u ? 1.0 : 0.0);
#    endif
    return color * SUNLIT_DEBUG_BRIGHTNESS;
}

#endif

#endif
