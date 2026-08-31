// The full-screen triangle every screen-space pass shares.
//
// Translated from shaders/glsl/full_screen.v.glsl, keeping its vertex numbering so the two
// produce the same triangle:
//
//   X <- vid == 0: (-1, -3)
//   |\
//   | \
//   |###\
//   |#+# \   `+` is (0, 0). `#`s are the viewport.
//   |###  \
//   X------X <- vid == 2: (3, 1)
//   ^
//   vid == 1: (-1, 1)
//
// The y sign is unchanged from the GLSL. OpenGL's clip space is +Y up and D3D's is too; the
// two differ in *texture* origin and in the depth range, neither of which this touches.

struct FullScreenVSOut {
    float4 position : SV_Position;
};

FullScreenVSOut fs_vs_main(uint vid : SV_VertexID) {
    FullScreenVSOut o;
    float4 position;
    position.x = (vid == 2) ? 3.0 : -1.0;
    position.y = (vid == 0) ? -3.0 : 1.0;
    position.z = 1.0;
    position.w = 1.0;
    o.position = position;
    return o;
}
