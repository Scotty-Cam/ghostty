//! The D3D11 backend's resource layer, as a module boundary.
//!
//! Two things make this file necessary, and neither is style.
//!
//! A Zig module's package root is the directory of its root file, and `@embedFile` may not
//! reach outside it. The backend embeds its HLSL from `renderer/shaders/hlsl/`, a sibling of
//! `renderer/d3d11/`, so a module rooted inside `d3d11/` cannot see the shaders and one rooted
//! here can. That matters to anything consuming the backend on its own -- the probe that
//! exercises it against a real driver, which must not drag in the whole renderer to do so.
//!
//! And the name is `d3d11_backend` rather than `d3d11` because macOS filesystems are
//! case-insensitive: `d3d11.zig` and `D3D11.zig` are one file there, and the graphics API
//! silently overwrote this one. It built, because both imports resolved to whichever file
//! survived. On Linux or Windows one of the two would not have existed at all -- so the bug
//! was invisible exactly on the machine the code is written on.

const impl = @import("d3d11/main.zig");

pub const api = impl.api;
pub const com = impl.com;
pub const Device = impl.Device;
pub const Texture = impl.Texture;
pub const Sampler = impl.Sampler;
pub const Pipeline = impl.Pipeline;
pub const Target = impl.Target;
pub const RenderPass = impl.RenderPass;
pub const buffer = impl.buffer;
pub const Buffer = impl.Buffer;
pub const sources = impl.sources;

test {
    @import("std").testing.refAllDecls(@This());
}
