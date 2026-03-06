#include "common.glsl"

layout(binding = 0) uniform sampler2DRect atlas_grayscale;
layout(binding = 1) uniform sampler2DRect atlas_color;

in CellTextVertexOut {
    flat uint atlas;
    flat vec4 color;
    flat vec4 bg_color;
    vec2 tex_coord;
} in_data;

// Values `atlas` can take.
const uint ATLAS_GRAYSCALE = 0u;
const uint ATLAS_COLOR = 1u;

layout(location = 0) out vec4 out_FragColor;

void main() {
    float a;
    switch (in_data.atlas) {
        default:
        case ATLAS_GRAYSCALE:
            a = texture(atlas_grayscale, in_data.tex_coord).r;
            break;
        case ATLAS_COLOR:
            a = texture(atlas_color, in_data.tex_coord).a;
            break;
    }

    out_FragColor = vec4(a, a, a, a);
}
