//! A render pass: a set of attachments and the steps drawn into them.
//!
//! D3D11 has no render-pass object, so this is a small amount of bookkeeping over the
//! immediate context: bind the attachment, clear once at the first step, then set state and
//! draw per step. The shape is the generic renderer's, not ours.

const std = @import("std");
const api = @import("api.zig");
const com = api.com;

const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const bufferpkg = @import("buffer.zig");

const Self = @This();
const log = std.log.scoped(.d3d11);

pub const Options = struct {
    attachments: []const Attachment,
    device: api.Device,
    context: api.Context,

    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?bufferpkg.Handle = null,
    buffers: []const ?bufferpkg.Handle = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    pub const Draw = struct {
        /// Only the two topologies the renderer uses.
        type: enum { triangle, triangle_strip },
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

attachments: []const Options.Attachment,
device: api.Device,
context: api.Context,
step_number: usize = 0,

pub fn begin(opts: Options) Self {
    return .{
        .attachments = opts.attachments,
        .device = opts.device,
        .context = opts.context,
    };
}

fn attachmentView(a: Options.Attachment) ?api.RenderTargetView {
    return switch (a.target) {
        .target => |t| t.view(),
        .texture => |t| t.rtv,
    };
}

fn attachmentSize(a: Options.Attachment) struct { w: f32, h: f32 } {
    return switch (a.target) {
        .target => |t| .{ .w = @floatFromInt(t.width), .h = @floatFromInt(t.height) },
        .texture => |t| .{ .w = @floatFromInt(t.width), .h = @floatFromInt(t.height) },
    };
}

/// Add a step to this pass.
///
/// Errors are reported and the step skipped, matching the OpenGL backend: a renderer that
/// stops drawing because one pass failed is worse than one that misses a pass, and the log
/// says which.
pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;
    const ctx = self.context;
    const attachment = self.attachments[0];

    const rtv = attachmentView(attachment) orelse {
        log.err("render pass attachment has no render-target view", .{});
        return;
    };
    var views = [_]?*anyopaque{rtv.ptr};
    ctx.vt().OMSetRenderTargets(ctx.ptr, 1, &views[0], null);

    // The viewport is set per step, not once.
    //
    // D3D11 resets no state between draws, but the post-processing chain switches attachments
    // mid-pass and each may be a different size. Setting it once at the first step left every
    // later step rendering through the first attachment's viewport.
    const size = attachmentSize(attachment);
    var viewport = com.D3D11_VIEWPORT{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = size.w,
        .Height = size.h,
        .MinDepth = 0,
        .MaxDepth = 1,
    };
    ctx.vt().RSSetViewports(ctx.ptr, 1, &viewport);

    if (self.step_number == 0) if (attachment.clear_color) |c| {
        var col = c;
        ctx.vt().ClearRenderTargetView(ctx.ptr, rtv.ptr, &col[0]);
    };
    defer self.step_number += 1;

    ctx.vt().IASetPrimitiveTopology(ctx.ptr, switch (s.draw.type) {
        .triangle => api.Topology.triangle_list,
        .triangle_strip => api.Topology.triangle_strip,
    });

    if (s.pipeline.layout) |l| ctx.vt().IASetInputLayout(ctx.ptr, l.ptr);
    ctx.vt().VSSetShader(ctx.ptr, s.pipeline.vs.ptr, null, 0);
    ctx.vt().PSSetShader(ctx.ptr, s.pipeline.ps.ptr, null, 0);

    // The uniform block is b0 in both stages. The GLSL binds it at index 1 to match Metal;
    // HLSL constant buffer registers are their own space, so b0 here is the same block.
    if (s.uniforms) |u| {
        var cbs = [_]?*anyopaque{u.resource.ptr};
        ctx.vt().VSSetConstantBuffers(ctx.ptr, 0, 1, &cbs[0]);
        ctx.vt().PSSetConstantBuffers(ctx.ptr, 0, 1, &cbs[0]);
    }

    // Textures occupy t0 upward, and storage buffers continue from where they stop.
    //
    // D3D11 gives shader-resource views one register space, so a texture and a structured
    // buffer compete for it -- unlike GLSL, where samplers and storage buffers are bound
    // separately and may both start at zero. The HLSL declares its registers on this
    // assumption: cell_text has its two atlases at t0 and t1 and the background colours at t2.
    var srvs: [8]?*anyopaque = @splat(null);
    var srv_count: u32 = 0;
    for (s.textures) |t| {
        if (srv_count >= srvs.len) break;
        srvs[srv_count] = if (t) |tex| tex.srv.ptr else null;
        srv_count += 1;
    }
    // Index 0 is the vertex buffer, not a storage buffer -- the generic renderer's convention.
    if (s.buffers.len > 1) {
        for (s.buffers[1..]) |b| {
            if (srv_count >= srvs.len) break;
            srvs[srv_count] = if (b) |bb| (if (bb.srv) |v| v.ptr else null) else null;
            srv_count += 1;
        }
    }
    if (srv_count > 0) {
        ctx.vt().VSSetShaderResources(ctx.ptr, 0, srv_count, &srvs[0]);
        ctx.vt().PSSetShaderResources(ctx.ptr, 0, srv_count, &srvs[0]);
    }

    var samplers: [4]?*anyopaque = @splat(null);
    var sampler_count: u32 = 0;
    for (s.samplers) |sm| {
        if (sampler_count >= samplers.len) break;
        samplers[sampler_count] = if (sm) |x| x.sampler.ptr else null;
        sampler_count += 1;
    }
    if (sampler_count > 0) {
        ctx.vt().VSSetSamplers(ctx.ptr, 0, sampler_count, &samplers[0]);
        ctx.vt().PSSetSamplers(ctx.ptr, 0, sampler_count, &samplers[0]);
    }

    if (s.buffers.len > 0) {
        if (s.buffers[0]) |vb| {
            var vbs = [_]?*anyopaque{vb.resource.ptr};
            var strides = [_]u32{s.pipeline.stride};
            var offsets = [_]u32{0};
            ctx.vt().IASetVertexBuffers(ctx.ptr, 0, 1, &vbs[0], &strides[0], &offsets[0]);
        }
    }

    // A null blend state is the default, which is blending disabled -- so the disabled case
    // needs no separate object.
    const blend_factor = [4]f32{ 0, 0, 0, 0 };
    var bf = blend_factor;
    ctx.vt().OMSetBlendState(
        ctx.ptr,
        if (s.pipeline.blend) |b| b.ptr else null,
        &bf[0],
        0xFFFFFFFF,
    );

    ctx.vt().DrawInstanced(
        ctx.ptr,
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
        0,
        0,
    );
}

/// Complete the pass.
///
/// Shader resources are unbound here, not left set. A texture still bound as an input when the
/// next pass binds it as a render target is a read/write hazard: D3D11 silently unbinds one of
/// them and the debug layer reports it, which is a warning nobody reads on a machine where the
/// debug layer is not installed.
pub fn complete(self: *const Self) void {
    const ctx = self.context;
    var none: [8]?*anyopaque = @splat(null);
    ctx.vt().VSSetShaderResources(ctx.ptr, 0, none.len, &none[0]);
    ctx.vt().PSSetShaderResources(ctx.ptr, 0, none.len, &none[0]);
}
