//! The D3D11 backend's modules, in one place.
//!
//! An index rather than a set of relative imports, so a consumer -- the graphics API above,
//! or the probe that exercises this layer on real hardware -- names one module. Zig refuses a
//! file that belongs to two module roots, and importing api.zig both directly and through
//! Device.zig is exactly that.

const std = @import("std");

pub const api = @import("api.zig");
pub const com = api.com;
pub const Device = @import("Device.zig");
pub const Texture = @import("Texture.zig");
pub const Sampler = @import("Sampler.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const Target = @import("Target.zig");
pub const RenderPass = @import("RenderPass.zig");
pub const buffer = @import("buffer.zig");
pub const Buffer = buffer.Buffer;

pub const sources = @import("sources.zig");

// `shaders.zig` is deliberately not re-exported here.
//
// It needs `../../math.zig` for the projection matrix, which is outside this directory -- and
// a module rooted at `renderer/` for the sake of @embedFile cannot reach it either. Only
// D3D11.zig needs the pipeline collection, and it is rooted where math is visible, so it
// imports that file directly and this index stays usable on its own.

test {
    @import("std").testing.refAllDecls(@This());
}
