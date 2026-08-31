// The text pass: one instanced quad per glyph.
//
// Translated from shaders/glsl/cell_text.v.glsl and cell_text.f.glsl.
//
// The GLSL derives its quad corner from gl_VertexID over a triangle strip and reads its
// per-glyph attributes as vertex inputs. Here the per-glyph data is an instance buffer and the
// corner comes from SV_VertexID over the same four-vertex strip, which keeps the vertex
// numbering -- and therefore the corner mapping -- identical to the reference.

#include "common.hlsl"

Texture2D<float>  atlas_grayscale : register(t0);
Texture2D<float4> atlas_color     : register(t1);
SamplerState      atlas_sampler   : register(s0);
StructuredBuffer<uint> bg_colors  : register(t2);

// Values `atlas` can take.
static const uint ATLAS_GRAYSCALE = 0u;
static const uint ATLAS_COLOR = 1u;

// Masks for the `glyph_bools` attribute
static const uint NO_MIN_CONTRAST = 1u;
static const uint IS_CURSOR_GLYPH = 2u;

struct Glyph {
    uint2 glyph_pos   : GLYPH_POS;
    uint2 glyph_size  : GLYPH_SIZE;
    int2  bearings    : BEARINGS;
    uint2 grid_pos    : GRID_POS;
    uint4 color       : COLOR;
    uint  atlas       : ATLAS;
    // BOOLS, not GLYPH_BOOLS: the input layout derives each semantic by upper-casing the Zig
    // field name, and that field is `bools`. A semantic the vertex struct does not produce is
    // not an error -- D3D11 simply never feeds it, and the shader reads zero.
    uint  glyph_bools : BOOLS;
};

struct VSOut {
    float4 position   : SV_Position;
    nointerpolation uint   atlas    : ATLAS;
    nointerpolation float4 color    : COLOR0;
    nointerpolation float4 bg_color : COLOR1;
    // Unnormalised, in texels: the atlas is sampled by pixel coordinate, as in the reference.
    float2 tex_coord  : TEXCOORD0;
};

VSOut vs_main(Glyph g, uint vid : SV_VertexID) {
    VSOut o;

    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    uint2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float2 cell_pos = cell_size * float2(g.grid_pos);

    //   0 --> 1
    //   |   .'|
    //   |  /  |
    //   | L   |
    //   2 --> 3
    float2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    o.atlas = g.atlas;

    float2 size = float2(g.glyph_size);
    float2 offset = float2(g.bearings);
    offset.y = cell_size.y - offset.y;

    cell_pos = cell_pos + size * corner + offset;
    o.position = mul(projection_matrix, float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f));

    o.tex_coord = float2(g.glyph_pos) + float2(g.glyph_size) * corner;

    o.color = load_color(g.color, true);
    o.bg_color = load_color(
        unpack4u8(bg_colors[g.grid_pos.y * grid_size.x + g.grid_pos.x]),
        true
    );
    float4 global_bg = load_color(unpack4u8(bg_color_packed_4u8), true);
    o.bg_color += global_bg * (1.0 - o.bg_color.a);

    if (min_contrast > 1.0f && (g.glyph_bools & NO_MIN_CONTRAST) == 0) {
        o.color = contrasted_color(min_contrast, o.color, o.bg_color);
    }

    bool is_cursor_pos =
        ((g.grid_pos.x == cursor_pos.x) || (cursor_wide && (g.grid_pos.x == (cursor_pos.x + 1)))) &&
        (g.grid_pos.y == cursor_pos.y);

    if ((g.glyph_bools & IS_CURSOR_GLYPH) == 0 && is_cursor_pos) {
        o.color = load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }

    return o;
}

float4 ps_main(VSOut input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0;

    if (input.atlas == ATLAS_COLOR) {
        // Colour glyphs are already premultiplied linear.
        float4 color = atlas_color.Load(int3(int2(input.tex_coord), 0));
        if (use_linear_blending) return color;
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;
        return color;
    }

    // ATLAS_GRAYSCALE, and the default.
    float4 color = input.color;

    if (!use_linear_blending) {
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;
    }

    // Load, not Sample: the reference uses sampler2DRect with pixel coordinates and nearest
    // filtering, and a filtered fetch would blend neighbouring glyphs in the atlas across
    // their shared edge.
    float a = atlas_grayscale.Load(int3(int2(input.tex_coord), 0));

    if (use_linear_correction) {
        float4 bg = input.bg_color;
        float fg_l = luminance(color.rgb);
        float bg_l = luminance(bg.rgb);
        if (abs(fg_l - bg_l) > 0.001) {
            float blend_l = linearize_f(unlinearize_f(fg_l) * a + unlinearize_f(bg_l) * (1.0 - a));
            a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
        }
    }

    color *= a;
    return color;
}
