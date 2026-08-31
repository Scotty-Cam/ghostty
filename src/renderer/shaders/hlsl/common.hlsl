// Shared definitions for the D3D11 backend's shaders.
//
// A translation of shaders/glsl/common.glsl, kept deliberately line-for-line comparable with
// it. Stage 1 asks that the blending behaviour match the reference, and the way to keep two
// implementations of a colour pipeline in step is for them to be readable side by side --
// every function here has the same name, the same arguments and the same order as its GLSL
// counterpart, even where HLSL would idiomatically spell it differently.
//
// Two real differences, neither cosmetic:
//
//   - GLSL's `mix(a, b, cutoff)` with a bvec selects componentwise. `lerp` reproduces it
//     exactly, but only because a bool-to-float cast is precisely 0.0 or 1.0 -- so the cast is
//     written out rather than left implicit, and the weight is never anything in between.
//     HLSL 2021 has `select`, which says this directly; fxc compiling Shader Model 5 does not
//     have it, and this backend targets fxc.
//   - Row-major versus column-major. HLSL defaults to column-major for matrices in constant
//     buffers while the projection is uploaded row-major, so the declaration says so rather
//     than the multiplication being flipped to compensate.

cbuffer Globals : register(b0) {
    // Column-major, which is HLSL's default for a constant buffer and what the matrix
    // actually is: the core builds it for GLSL, where a mat4 in std140 is column-major.
    // Declared `row_major` it is transposed on read, and every position the vertex stage
    // computes lands somewhere else -- the glyph quads came out as a wedge across the window
    // while the full-screen passes, which never touch the matrix, rendered correctly.
    float4x4 projection_matrix;
    float2 screen_size;
    float2 cell_size;
    uint   grid_size_packed_2u16;
    float4 grid_padding;
    uint   padding_extend;
    float  min_contrast;
    uint   cursor_pos_packed_2u16;
    uint   cursor_color_packed_4u8;
    uint   bg_color_packed_4u8;
    uint   bools;
};

// Bools
static const uint CURSOR_WIDE = 1u;
static const uint USE_DISPLAY_P3 = 2u;
static const uint USE_LINEAR_BLENDING = 4u;
static const uint USE_LINEAR_CORRECTION = 8u;

// Padding extend enum
static const uint EXTEND_LEFT = 1u;
static const uint EXTEND_RIGHT = 2u;
static const uint EXTEND_UP = 4u;
static const uint EXTEND_DOWN = 8u;

//----------------------------------------------------------------------------//
// Functions for Unpacking Values
//----------------------------------------------------------------------------//
// As in the GLSL, these assume little-endian.

uint4 unpack4u8(uint packed_value) {
    return uint4(
        (packed_value >> 0)  & 0xFFu,
        (packed_value >> 8)  & 0xFFu,
        (packed_value >> 16) & 0xFFu,
        (packed_value >> 24) & 0xFFu
    );
}

uint2 unpack2u16(uint packed_value) {
    return uint2(
        (packed_value >> 0)  & 0xFFFFu,
        (packed_value >> 16) & 0xFFFFu
    );
}

int2 unpack2i16(int packed_value) {
    return int2(
        (packed_value << 16) >> 16,
        (packed_value << 0)  >> 16
    );
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

float luminance(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

float contrast_ratio(float3 color1, float3 color2) {
    float luminance1 = luminance(color1) + 0.05;
    float luminance2 = luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

float4 contrasted_color(float min_ratio, float4 fg, float4 bg) {
    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(float3(1.0, 1.0, 1.0), bg.rgb);
        float black_ratio = contrast_ratio(float3(0.0, 0.0, 0.0), bg.rgb);
        if (white_ratio > black_ratio) {
            return float4(1.0, 1.0, 1.0, 1.0);
        } else {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }
    return fg;
}

// sRGB to linear. `select` and not `lerp`: the GLSL selects componentwise on a bvec, and a
// lerp on the comparison would interpolate between the two branches instead of choosing one.
float4 linearize(float4 srgb) {
    bool3 cutoff = srgb.rgb <= float3(0.04045, 0.04045, 0.04045);
    float3 higher = pow((srgb.rgb + 0.055) / 1.055, 2.4);
    float3 lower = srgb.rgb / 12.92;
    return float4(lerp(higher, lower, float3(cutoff)), srgb.a);
}

float linearize_f(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

float4 unlinearize(float4 linear_color) {
    bool3 cutoff = linear_color.rgb <= float3(0.0031308, 0.0031308, 0.0031308);
    float3 higher = pow(linear_color.rgb, 1.0 / 2.4) * 1.055 - 0.055;
    float3 lower = linear_color.rgb * 12.92;
    return float4(lerp(higher, lower, float3(cutoff)), linear_color.a);
}

float unlinearize_f(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Load a 4 byte RGBA non-premultiplied color, linearizing if asked, and premultiply.
float4 load_color(uint4 in_color, bool linear_out) {
    float4 color = float4(in_color) / 255.0f;
    if (linear_out) color = linearize(color);
    color.rgb *= color.a;
    return color;
}
