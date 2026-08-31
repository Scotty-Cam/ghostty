//! Graphics API wrapper for Direct3D 11.
//!
//! Selected by ADR-002. Every COM interface, GUID and Windows struct reachable from here comes
//! from `d3d11/com.zig`, generated from pinned Windows metadata; `tools/parity/lint_com.py`
//! fails the build on a hand-written vtable or IID in this directory.
pub const D3D11 = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(D3D11);

const d3d11 = @import("d3d11/main.zig");

pub const GraphicsAPI = D3D11;
pub const Target = d3d11.Target;
pub const Frame = @import("d3d11/Frame.zig");
pub const RenderPass = d3d11.RenderPass;
pub const Pipeline = d3d11.Pipeline;
const bufferpkg = d3d11.buffer;
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = d3d11.Sampler;
pub const Texture = d3d11.Texture;
pub const shaders = @import("d3d11/shaders.zig");

const api = d3d11.api;
const log = std.log.scoped(.d3d11);

/// Custom shaders are HLSL, and shadertoy translation targets GLSL or MSL. Declared as GLSL
/// because that is the closest of the two; a custom shader is compiled by the same D3DCompile
/// path as a built-in one and will fail loudly if it is not HLSL.
pub const custom_shader_target: shadertoy.Target = .glsl;

/// D3D clip space is +Y up, like OpenGL's, so fragCoord is not flipped.
pub const custom_shader_y_is_down = false;

/// Two, matching the swap chain. A third buffer buys latency hiding a terminal does not need
/// and costs a frame of memory on a machine that may have very little.
pub const swap_chain_count = 2;

alloc: Allocator,
blending: configpkg.Config.AlphaBlending,
device: d3d11.Device,
/// The most recently presented target, so a frame can be presented again without redrawing.
last_target: ?Target = null,
/// Drives frames. See `loopEnter`.
frame_thread: ?std.Thread = null,
/// Built on first present. See `blitPipeline`.
blit: ?Pipeline = null,
blit_sampler: ?Sampler = null,
frame_stop: std.atomic.Value(bool) = .init(false),

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !D3D11 {
    const hwnd: ?*anyopaque = switch (apprt.runtime) {
        apprt.embedded => switch (opts.rt_surface.platform) {
            .windows => |w| w.hwnd,
            // D3D11 is only built for Windows, where the Darwin arms are void and cannot be
            // constructed. Handled explicitly so a new platform is a compile error here rather
            // than something that falls through.
            .macos, .ios => unreachable,
        },
        else => @compileError("unsupported apprt for D3D11"),
    };

    // The debug layer is asked for in a debug build and is not required: it is an optional
    // Windows component, absent on a stock install, and requesting it on a machine without it
    // fails device creation outright. `Device.init` retries without it.
    var device = try d3d11.Device.init(builtin.mode == .Debug);
    errdefer device.deinit();

    const size = opts.rt_surface.getSize() catch |err| {
        log.warn("could not read the surface size, err={}", .{err});
        return err;
    };
    try device.attach(hwnd, size.width, size.height);

    log.info("D3D11 device created driver={s} feature_level=0x{x}", .{
        @tagName(device.driver), device.feature_level,
    });

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = device,
    };
}

pub fn deinit(self: *D3D11) void {
    self.loopExit();
    if (self.blit) |p| p.deinit();
    if (self.blit_sampler) |smp| smp.deinit();
    if (self.last_target) |*t| t.deinit();
    self.device.deinit();
    self.* = undefined;
}

/// Nothing to do early in surface creation: the device is built in `init`, which already has
/// the window handle.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;
}

pub fn finalizeSurfaceInit(self: *const D3D11, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

/// D3D11 device contexts are not thread-affine the way a GL context is, so there is nothing to
/// make current when the renderer thread starts.
pub fn threadEnter(self: *const D3D11, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

pub fn threadExit(self: *const D3D11) void {
    _ = self;
}

/// Start driving frames.
///
/// Nothing else does on Windows. The render thread's own draw timer only runs when a custom
/// shader is animating, and `draw_now` -- which its comment calls "the only way to trigger a
/// drawFrame" -- is notified from exactly one place in the whole renderer: the macOS display
/// link callback. So a Windows surface came up, sized itself, started its render thread, and
/// then drew nothing, forever, with no error anywhere.
///
/// Metal solves this in `loopEnter` by registering a display-link callback, and this is the
/// same shape: a thread that paces frames and calls `drawFrame` on the renderer. It is the
/// backend's job because the pacing source is the backend's -- here, the swap chain.
pub fn loopEnter(self: *D3D11) void {
    if (self.frame_thread != null) return;
    const renderer: *align(1) Renderer = @fieldParentPtr("api", self);
    self.frame_stop.store(false, .seq_cst);
    self.frame_thread = std.Thread.spawn(.{}, frameLoop, .{ self, renderer }) catch |err| {
        log.err("could not start the frame thread, nothing will draw: err={}", .{err});
        return;
    };
}

pub fn loopExit(self: *D3D11) void {
    const t = self.frame_thread orelse return;
    self.frame_stop.store(true, .seq_cst);
    t.join();
    self.frame_thread = null;
}

/// Ask for a frame at a steady cadence.
///
/// A sleep, not a wait on the swap chain's waitable object. The waitable object is the right
/// pacing source and wants the chain created with FRAME_LATENCY_WAITABLE_OBJECT; this is the
/// smaller first step, and `present` already refuses to submit an unchanged frame, so an
/// unnecessary wake costs a comparison rather than a present.
fn frameLoop(self: *D3D11, renderer: *align(1) Renderer) void {
    // The alignment is 1 because `@fieldParentPtr` from a field of an over-aligned struct
    // cannot promise more; `drawFrame` wants a naturally aligned pointer and the object really
    // is aligned, so the cast states what the type system cannot infer.
    const interval_ns: u64 = 8 * std.time.ns_per_ms; // 120 Hz, matching Thread.DRAW_INTERVAL
    while (!self.frame_stop.load(.seq_cst)) {
        std.Thread.sleep(interval_ns);
        const r: *Renderer = @alignCast(renderer);
        r.drawFrame(true) catch |err| {
            log.warn("error drawing frame err={}", .{err});
        };
    }
}

pub fn drawFrameStart(self: *D3D11) void {
    _ = self;
}

pub fn drawFrameEnd(self: *D3D11) void {
    _ = self;
}

pub fn initShaders(
    self: *const D3D11,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    return try shaders.Shaders.init(alloc, self.device.device, custom_shaders);
}

pub fn surfaceSize(self: *const D3D11) !struct { width: u32, height: u32 } {
    return .{ .width = self.device.width, .height = self.device.height };
}

pub fn initTarget(self: *const D3D11, width: usize, height: usize) !Target {
    return Target.init(.{
        .width = width,
        .height = height,
        // An sRGB target makes the GPU gamma-encode after blending, which is what gives
        // linear alpha blending rather than gamma-incorrect blending. `present` draws this
        // into the back buffer rather than copying it, so the formats need not match.
        .srgb = self.blending.isLinear(),
        .device = self.device.device,
        .context = self.device.context,
    });
}

/// Present a target by copying it into the back buffer.
///
/// A copy rather than a draw. The target and the back buffer are the same size and format, so
/// CopyResource is exact and needs no pipeline state -- and a full-screen blit here would have
/// to re-establish every piece of state the last pass left set.
pub fn present(self: *D3D11, target: Target) !void {
    const ctx = self.device.context;
    if (self.device.rtv) |back_rtv| {
        // Drawn, not copied.
        //
        // CopyResource requires identical formats, and the target is sRGB while a flip-model
        // swap chain cannot be. The copy was refused, silently -- it returns void, and only the
        // debug layer says a word -- so the window went on displaying the previous frame, which
        // is indistinguishable from a renderer that never drew.
        //
        // Sampling decodes the sRGB target to linear and the write stores it back unchanged
        // into the UNORM back buffer, which is the encoded value the target already held.
        const pipeline = try self.blitPipeline();
        var views = [_]?*anyopaque{back_rtv.ptr};
        ctx.vt().OMSetRenderTargets(ctx.ptr, 1, &views[0], null);

        var viewport = d3d11.com.D3D11_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(self.device.width),
            .Height = @floatFromInt(self.device.height),
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        ctx.vt().RSSetViewports(ctx.ptr, 1, &viewport);
        ctx.vt().IASetPrimitiveTopology(ctx.ptr, api.Topology.triangle_list);
        ctx.vt().IASetInputLayout(ctx.ptr, null);
        ctx.vt().VSSetShader(ctx.ptr, pipeline.vs.ptr, null, 0);
        ctx.vt().PSSetShader(ctx.ptr, pipeline.ps.ptr, null, 0);

        var srvs = [_]?*anyopaque{target.texture.srv.ptr};
        ctx.vt().PSSetShaderResources(ctx.ptr, 0, 1, &srvs[0]);
        var samplers = [_]?*anyopaque{(try self.blitSampler()).sampler.ptr};
        ctx.vt().PSSetSamplers(ctx.ptr, 0, 1, &samplers[0]);

        // No blending: this replaces the back buffer rather than compositing onto it.
        var bf = [4]f32{ 0, 0, 0, 0 };
        ctx.vt().OMSetBlendState(ctx.ptr, null, &bf[0], 0xFFFFFFFF);
        ctx.vt().Draw(ctx.ptr, 3, 0);

        // Unbound before presenting: the target is a shader input here and a render target on
        // the next frame, and D3D11 resolves that hazard by silently dropping one of them.
        var none = [_]?*anyopaque{null};
        ctx.vt().PSSetShaderResources(ctx.ptr, 0, 1, &none[0]);
    }
    self.device.dirty = true;
    try self.device.present(false);
    self.last_target = target;
}

/// The pipeline `present` draws with, built on first use.
///
/// Lazily, because it needs the device and `init` builds that; and here rather than in the
/// renderer's shader set because it is not one of the renderer's passes -- the generic renderer
/// never asks for it and `present` cannot reach the shaders from the api.
fn blitPipeline(self: *D3D11) !Pipeline {
    if (self.blit) |p| return p;
    const p = try Pipeline.init(null, .{
        .source = d3d11.sources.blit,
        .name = "blit",
        .blending_enabled = false,
        .device = self.device.device,
    });
    self.blit = p;
    return p;
}

fn blitSampler(self: *D3D11) !Sampler {
    if (self.blit_sampler) |s| return s;
    const s = try Sampler.init(.{
        // Point sampling: the target and the back buffer are the same size, so every texel
        // maps to one pixel and filtering would only soften text.
        .filter = .nearest,
        .wrap = .clamp,
        .device = self.device.device,
    });
    self.blit_sampler = s;
    return s;
}

pub fn presentLastTarget(self: *D3D11) !void {
    if (self.last_target) |target| try self.present(target);
}

/// Resize the swap chain to match the window.
///
/// Called by the shell when the window changes size. The renderer's own targets are managed by
/// the generic renderer; this is only the chain the frames are shown through.
pub fn resize(self: *D3D11, width: u32, height: u32) !void {
    try self.device.resize(width, height);
}

pub inline fn bufferOptions(self: D3D11) bufferpkg.Options {
    return .{ .kind = .vertex, .device = self.device.device, .context = self.device.context };
}

pub inline fn uniformBufferOptions(self: D3D11) bufferpkg.Options {
    return .{ .kind = .constant, .device = self.device.device, .context = self.device.context };
}

/// The cell colour buffers are read as StructuredBuffers, not vertex buffers: the shader
/// indexes them by grid position rather than receiving one element per instance.
pub inline fn bgBufferOptions(self: D3D11) bufferpkg.Options {
    return .{ .kind = .structured, .device = self.device.device, .context = self.device.context };
}

pub const instanceBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub inline fn textureOptions(self: D3D11) Texture.Options {
    return .{
        .format = .bgra8_srgb,
        .device = self.device.device,
        .context = self.device.context,
    };
}

pub inline fn samplerOptions(self: D3D11) Sampler.Options {
    return .{ .filter = .linear, .wrap = .clamp, .device = self.device.device };
}

pub const ImageTextureFormat = enum {
    gray,
    rgba,
    bgra,

    fn toTextureFormat(self: ImageTextureFormat) Texture.Format {
        return switch (self) {
            .gray => .r8,
            .rgba => .rgba8,
            .bgra => .bgra8,
        };
    }
};

pub inline fn imageTextureOptions(
    self: D3D11,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = srgb;
    return .{
        .format = format.toTextureFormat(),
        .device = self.device.device,
        .context = self.device.context,
    };
}

/// A texture for the font atlas.
///
/// Nearest filtering and no sRGB, matching the other backends: the atlas is sampled by pixel
/// coordinate and its grayscale coverage is a mask rather than a colour, so linearising it
/// would apply a transfer function to a number that is not one.
pub fn initAtlasTexture(
    self: *const D3D11,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const format: Texture.Format = switch (atlas.format) {
        .grayscale => .r8,
        .bgra => .bgra8,
        else => @panic("unsupported atlas format for a D3D11 texture"),
    };
    return try Texture.init(
        .{
            .format = format,
            .device = self.device.device,
            .context = self.device.context,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

pub inline fn beginFrame(
    self: *const D3D11,
    renderer: *Renderer,
    target: *Target,
) !Frame {
    return try Frame.begin(.{
        .device = self.device.device,
        .context = self.device.context,
    }, renderer, target);
}
