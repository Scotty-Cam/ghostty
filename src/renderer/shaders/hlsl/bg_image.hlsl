// The background-image pass: a full-screen triangle, with fit and position resolved per draw.
//
// Translated from shaders/glsl/bg_image.v.glsl and bg_image.f.glsl.
//
// The GLSL is instanced with two per-instance attributes and emits its own full-screen
// triangle rather than sharing full_screen.v.glsl, so this does the same.

#include "common.hlsl"

Texture2D<float4> image         : register(t0);
SamplerState      image_sampler : register(s0);

// 4 bits of info.
static const uint BG_IMAGE_POSITION = 15u;
static const uint BG_IMAGE_TL = 0u;
static const uint BG_IMAGE_TC = 1u;
static const uint BG_IMAGE_TR = 2u;
static const uint BG_IMAGE_ML = 3u;
static const uint BG_IMAGE_MC = 4u;
static const uint BG_IMAGE_MR = 5u;
static const uint BG_IMAGE_BL = 6u;
static const uint BG_IMAGE_BC = 7u;
static const uint BG_IMAGE_BR = 8u;

// 2 bits of info shifted 4.
static const uint BG_IMAGE_FIT = 3u << 4;
static const uint BG_IMAGE_CONTAIN = 0u << 4;
static const uint BG_IMAGE_COVER = 1u << 4;
static const uint BG_IMAGE_STRETCH = 2u << 4;
static const uint BG_IMAGE_NO_FIT = 3u << 4;

// 1 bit of info shifted 6.
static const uint BG_IMAGE_REPEAT = 1u << 6;

struct BgImage {
    float in_opacity : OPACITY;
    uint  info       : INFO;
};

struct VSOut {
    float4 position : SV_Position;
    nointerpolation float4 bg_color : COLOR0;
    nointerpolation float2 offset   : OFFSET;
    nointerpolation float2 scale    : SCALE;
    nointerpolation float  opacity  : OPACITY;
    // A uint rather than a bool, as in the reference: an interpolated bool is not something
    // the GLSL is allowed to declare, and matching the type keeps the two comparable.
    nointerpolation uint   repeat   : REPEAT;
};

VSOut vs_main(BgImage inst, uint vid : SV_VertexID) {
    VSOut o;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 position;
    position.x = (vid == 2) ? 3.0 : -1.0;
    position.y = (vid == 0) ? -3.0 : 1.0;
    position.z = 1.0;
    position.w = 1.0;
    o.position = position;

    o.opacity = inst.in_opacity;
    o.repeat = inst.info & BG_IMAGE_REPEAT;

    uint tw, th;
    image.GetDimensions(tw, th);
    float2 tex_size = float2(tw, th);

    float2 dest_size = tex_size;
    uint fit = inst.info & BG_IMAGE_FIT;
    if (fit == BG_IMAGE_CONTAIN) {
        float s = min(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_COVER) {
        float s = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_STRETCH) {
        dest_size = screen_size;
    } else if (fit == BG_IMAGE_NO_FIT) {
        dest_size = tex_size;
    }

    float2 start = float2(0.0, 0.0);
    float2 mid = (screen_size - dest_size) / 2.0;
    float2 end = screen_size - dest_size;

    float2 dest_offset = mid;
    uint pos = inst.info & BG_IMAGE_POSITION;
    if      (pos == BG_IMAGE_TL) dest_offset = float2(start.x, start.y);
    else if (pos == BG_IMAGE_TC) dest_offset = float2(mid.x,   start.y);
    else if (pos == BG_IMAGE_TR) dest_offset = float2(end.x,   start.y);
    else if (pos == BG_IMAGE_ML) dest_offset = float2(start.x, mid.y);
    else if (pos == BG_IMAGE_MC) dest_offset = float2(mid.x,   mid.y);
    else if (pos == BG_IMAGE_MR) dest_offset = float2(end.x,   mid.y);
    else if (pos == BG_IMAGE_BL) dest_offset = float2(start.x, end.y);
    else if (pos == BG_IMAGE_BC) dest_offset = float2(mid.x,   end.y);
    else if (pos == BG_IMAGE_BR) dest_offset = float2(end.x,   end.y);

    o.offset = dest_offset;
    o.scale = tex_size / dest_size;

    // A fully opaque background colour, with the alpha carried separately, because the
    // fragment stage needs them apart.
    uint4 u_bg_color = unpack4u8(bg_color_packed_4u8);
    o.bg_color = float4(
        load_color(uint4(u_bg_color.rgb, 255), use_linear_blending).rgb,
        float(u_bg_color.a) / 255.0
    );

    return o;
}

float4 ps_main(VSOut input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // SV_Position is origin-upper-left, which is what the GLSL requests explicitly.
    float2 tex_coord = (input.position.xy - input.offset) * input.scale;

    uint tw, th;
    image.GetDimensions(tw, th);
    float2 tex_size = float2(tw, th);

    if (input.repeat != 0) {
        // GLSL `mod` is a floored modulus and HLSL `fmod` is truncated, so they disagree in
        // sign for negative inputs -- which is exactly the case this line exists to handle.
        // The reference already double-mods to force a positive result, and the same
        // expression works here only because the inner term is written the floored way.
        tex_coord = tex_coord - tex_size * floor(tex_coord / tex_size);
    }

    float4 rgba;
    if (any(tex_coord < float2(0.0, 0.0)) || any(tex_coord > tex_size)) {
        rgba = float4(0.0, 0.0, 0.0, 0.0);
    } else {
        rgba = image.Sample(image_sampler, tex_coord / tex_size);
        if (!use_linear_blending) {
            rgba = unlinearize(rgba);
        }
        rgba.rgb *= rgba.a;
    }

    rgba *= min(input.opacity, 1.0 / input.bg_color.a);
    rgba += max(float4(0.0, 0.0, 0.0, 0.0), float4(input.bg_color.rgb, 1.0) * (1.0 - rgba.a));
    rgba *= input.bg_color.a;

    return rgba;
}
