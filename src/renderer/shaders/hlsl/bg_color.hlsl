// The flat background colour pass.
//
// Translated from shaders/glsl/bg_color.f.glsl.

#include "common.hlsl"
#include "full_screen.hlsl"

FullScreenVSOut vs_main(uint vid : SV_VertexID) {
    return fs_vs_main(vid);
}

float4 ps_main(FullScreenVSOut input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    return load_color(unpack4u8(bg_color_packed_4u8), use_linear_blending);
}
