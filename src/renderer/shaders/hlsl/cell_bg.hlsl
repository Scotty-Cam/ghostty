// The background pass: one full-screen triangle, each pixel resolved to a grid cell.
//
// Translated from shaders/glsl/cell_bg.f.glsl and full_screen.v.glsl.
//
// The cell colours arrive in a StructuredBuffer rather than an SSBO. D3D11 has no
// shader-storage-buffer equivalent, and a constant buffer cannot hold a grid's worth of cells
// -- the limit is 4096 float4s, which a 200x50 grid exceeds. A structured buffer read through
// a shader-resource view is the shape that fits, and it is read-only, which the GLSL's
// `readonly buffer` also says.

#include "common.hlsl"
#include "full_screen.hlsl"

StructuredBuffer<uint> cells : register(t0);

// The same triangle as every other screen-space pass, which is what the reference does: both
// bg_color and cell_bg name full_screen.v.glsl as their vertex stage. An equivalent triangle
// written out again here would drift the first time one of them changed.
FullScreenVSOut vs_main(uint vid : SV_VertexID) {
    return fs_vs_main(vid);
}

float4 cell_bg(float4 frag_coord) {
    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    // SV_Position is already origin-upper-left in D3D, which is what the GLSL asks for
    // explicitly with layout(origin_upper_left). No flip here is correct, not an omission.
    int2 grid_pos = int2(floor((frag_coord.xy - grid_padding.wx) / cell_size));
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 bg = float4(0.0, 0.0, 0.0, 0.0);

    if (grid_pos.x < 0) {
        if ((padding_extend & EXTEND_LEFT) != 0) {
            grid_pos.x = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.x > int(grid_size.x) - 1) {
        if ((padding_extend & EXTEND_RIGHT) != 0) {
            grid_pos.x = int(grid_size.x) - 1;
        } else {
            return bg;
        }
    }

    if (grid_pos.y < 0) {
        if ((padding_extend & EXTEND_UP) != 0) {
            grid_pos.y = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.y > int(grid_size.y) - 1) {
        if ((padding_extend & EXTEND_DOWN) != 0) {
            grid_pos.y = int(grid_size.y) - 1;
        } else {
            return bg;
        }
    }

    float4 cell_color = load_color(
        unpack4u8(cells[grid_pos.y * int(grid_size.x) + grid_pos.x]),
        use_linear_blending
    );

    return cell_color;
}

float4 ps_main(FullScreenVSOut input) : SV_Target {
    return cell_bg(input.position);
}
