//! An offscreen render target.
//!
//! The generic renderer draws into a target and then asks the API to present it, rather than
//! drawing straight to the back buffer -- that indirection is what lets the post-processing
//! chain run and what lets a frame be presented twice without redrawing it. So a target here
//! is a texture with a render-target view, and presenting is a copy into the swap chain.

const std = @import("std");
const api = @import("api.zig");
const Texture = @import("Texture.zig");

const Self = @This();

pub const Options = struct {
    width: usize,
    height: usize,
    /// Whether the target is sampled as sRGB. The linear-blending config decides this, and it
    /// has to match what the shaders assume or every colour is off by a gamma curve.
    srgb: bool = false,
    device: api.Device,
    context: api.Context,
};

texture: Texture,
width: usize,
height: usize,

pub fn init(opts: Options) api.Error!Self {
    const texture = try Texture.init(
        .{
            .format = if (opts.srgb) .bgra8_srgb else .bgra8,
            .render_target = true,
            .device = opts.device,
            .context = opts.context,
        },
        opts.width,
        opts.height,
        null,
    );
    return .{ .texture = texture, .width = opts.width, .height = opts.height };
}

pub fn deinit(self: *Self) void {
    self.texture.deinit();
}

/// See `Texture.retain`. A `Target` is a value type too, and the same rule applies to it.
pub fn retain(self: Self) void {
    self.texture.retain();
}

/// The view to draw into.
pub fn view(self: Self) api.RenderTargetView {
    // A target is always created as a render target, so this is present by construction.
    return self.texture.rtv.?;
}
