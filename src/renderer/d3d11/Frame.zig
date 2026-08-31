//! A frame: the render passes for one drawing of the terminal, and its presentation.
//!
//! D3D11's immediate context has no command buffer to submit, so a frame here is bookkeeping
//! rather than an object the driver knows about. What it does carry is the completion
//! contract: the generic renderer expects `frameCompleted` to be called with a health status,
//! and expects the target to have been presented if the frame was healthy.

const std = @import("std");
const api = @import("api.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const D3D11 = @import("../D3D11.zig");
const Renderer = @import("../generic.zig").Renderer(D3D11);
const Health = @import("../../renderer.zig").Health;

const Self = @This();
const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: api.Device,
    context: api.Context,
};

renderer: *Renderer,
target: *Target,
device: api.Device,
context: api.Context,

pub fn begin(opts: Options, renderer: *Renderer, target: *Target) !Self {
    return .{
        .renderer = renderer,
        .target = target,
        .device = opts.device,
        .context = opts.context,
    };
}

pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .attachments = attachments,
        .device = self.device,
        .context = self.context,
    });
}

/// Complete the frame and present it.
///
/// Health comes from the device rather than from the draw calls. D3D11 draws do not return a
/// status -- they are recorded and fail later, if at all -- so the thing worth asking is
/// whether the device is still there. `GetDeviceRemovedReason` answers exactly that, and it is
/// the only call in the frame path that can distinguish a lost adapter from a slow one.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;

    const removed = self.device.vt().GetDeviceRemovedReason(self.device.ptr);
    const health: Health = if (removed == api.S_OK) .healthy else .unhealthy;

    if (health == .healthy) {
        self.renderer.api.present(self.target.*) catch |err| {
            log.err("failed to present the render target: err={}", .{err});
        };
    } else {
        log.err("device removed: 0x{x:0>8}", .{@as(u32, @bitCast(removed))});
    }

    self.renderer.frameCompleted(health);
}
