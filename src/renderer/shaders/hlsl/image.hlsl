// The image pass: one instanced quad per placement.
//
// Translated from shaders/glsl/image.v.glsl and image.f.glsl.

#include "common.hlsl"

Texture2D<float4> image        : register(t0);
SamplerState      image_sampler : register(s0);

struct Placement {
    float2 grid_pos    : GRID_POS;
    float2 cell_offset : CELL_OFFSET;
    float4 source_rect : SOURCE_RECT;
    float2 dest_size   : DEST_SIZE;
};

struct VSOut {
    float4 position  : SV_Position;
    float2 tex_coord : TEXCOORD0;
};

VSOut vs_main(Placement p, uint vid : SV_VertexID) {
    VSOut o;

    //   0 --> 1
    //   |   .'|
    //   | L   |
    //   2 --> 3
    float2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    float2 tex_coord = p.source_rect.xy;
    tex_coord += p.source_rect.zw * corner;

    // Normalised against the texture's own size. GLSL reads it with textureSize(); HLSL asks
    // the resource with GetDimensions, which needs somewhere to write, hence the locals.
    uint tw, th;
    image.GetDimensions(tw, th);
    tex_coord /= float2(tw, th);
    o.tex_coord = tex_coord;

    float2 image_pos = (cell_size * p.grid_pos) + p.cell_offset;
    image_pos += p.dest_size * corner;

    o.position = mul(projection_matrix, float4(image_pos.xy, 1.0, 1.0));
    return o;
}

float4 ps_main(VSOut input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 rgba = image.Sample(image_sampler, input.tex_coord);
    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }
    rgba.rgb *= rgba.a;
    return rgba;
}
