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
///
/// It is asked TWICE, and that is the point of this function's shape. The first version asked
/// once, before presenting, and reported that answer -- so on the frame where the device
/// actually goes away the sequence was: the reason is still S_OK, health is healthy, `Present`
/// is the call that first observes the removal, its error is logged and swallowed, and
/// `frameCompleted` is told healthy. The one frame that knows the device died reported it
/// fine, and the error carrying the reason was thrown away.
///
/// That is not merely a late report. `health` is what any recovery path has to key off, so a
/// health signal that cannot see the failure it exists to report makes recovery unreachable.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;

    var removed = self.device.vt().GetDeviceRemovedReason(self.device.ptr);
    var health: Health = if (removed == api.S_OK) .healthy else .unhealthy;

    if (health == .healthy) {
        self.renderer.api.present(self.target.*) catch |err| {
            // Ask again. A present that fails on a live device is one thing -- an occluded
            // window, a transient -- and a present that fails because the adapter is gone is
            // another, and only the device can tell them apart. Deciding here on the strength
            // of the error alone would guess.
            removed = self.device.vt().GetDeviceRemovedReason(self.device.ptr);
            if (removed != api.S_OK) {
                health = .unhealthy;
                log.err(
                    "device removed, observed by Present: reason=0x{x:0>8} err={}",
                    .{ @as(u32, @bitCast(removed)), err },
                );
            } else {
                log.err("failed to present the render target on a live device: err={}", .{err});
            }
        };
    } else {
        log.err("device removed: 0x{x:0>8}", .{@as(u32, @bitCast(removed))});
    }

    self.renderer.frameCompleted(health);
}
