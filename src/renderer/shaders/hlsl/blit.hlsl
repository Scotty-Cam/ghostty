// Draw a render target into the back buffer.
//
// `present` used to copy with CopyResource, which requires identical formats and sizes. That
// forced the target to be UNORM, because a flip-model swap chain cannot be sRGB -- and an
// sRGB target is what makes the GPU gamma-encode after blending, which is what linear alpha
// blending means. Without it the shaders linearise and nothing encodes on write, so every
// colour arrives too dark.
//
// A draw has neither constraint. The target can be sRGB, sampling it decodes to linear, and
// writing to the UNORM back buffer stores exactly what was sampled -- which is the encoded
// value the target already holds.

Texture2D<float4> source : register(t0);
SamplerState      samp   : register(s0);

struct VSOut {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
};

VSOut vs_main(uint vid : SV_VertexID) {
    VSOut o;
    // The same oversized triangle the other screen-space passes use, with texture
    // coordinates. +Y is down in texture space and up in clip space, hence the flip.
    float2 uv = float2((vid << 1) & 2, vid & 2);
    o.uv = uv;
    o.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

// Re-encode on the way out.
//
// Sampling an sRGB texture decodes it to linear, and writing to the UNORM back buffer stores
// what it is given without encoding. Straight through, that loses exactly the transfer function
// the sRGB target applied when the renderer wrote to it, and the whole picture arrives too
// dark -- a terminal background of 40,44,52 leaves as 5,6,8.
//
// The alternative is a non-sRGB shader-resource view over the same resource, so no decode
// happens at all. That needs a D3D11_SHADER_RESOURCE_VIEW_DESC, and the generated bindings
// cannot express one: its payload is an anonymous union that Win32 metadata names the same as
// 567 others. Doing it in the shader costs one pow per pixel of one full-screen pass.
float3 encode_srgb(float3 c) {
    bool3 cutoff = c <= float3(0.0031308, 0.0031308, 0.0031308);
    float3 higher = pow(c, 1.0 / 2.4) * 1.055 - 0.055;
    float3 lower = c * 12.92;
    return lerp(higher, lower, float3(cutoff));
}

float4 ps_main(VSOut input) : SV_Target {
    float4 c = source.Sample(samp, input.uv);
    return float4(encode_srgb(c.rgb), c.a);
}
