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

    // Native blending, whatever the configuration asks for, until `present` can blit.
    //
    // Linear blending needs the render target to gamma-encode on write, which means an sRGB
    // format. `present` copies the target into the back buffer with CopyResource, which
    // requires identical formats, and a flip-model swap chain cannot be sRGB -- the model
    // permits only R8G8B8A8_UNORM, B8G8R8A8_UNORM and R16G16B16A16_FLOAT. An sRGB *view* over
    // a UNORM resource would resolve it, and the view descriptor cannot be built from the
    // generated bindings: D3D11_RENDER_TARGET_VIEW_DESC carries one of the anonymous unions
    // the metadata gives no usable name.
    //
    // So the target stays UNORM and the shaders are told not to assume linear blending, which
    // is what `native` means. Rendering is correct; it is gamma-incorrect blending, which is
    // what most terminals do and what this one did before ADR-002.
    //
    // The real fix is for `present` to draw the target through a shader rather than copy it,
    // which also removes the size and format constraints. Recorded as a gap rather than left
    // as a surprise: with the target sRGB and the copy failing, the window kept displaying the
    // frame before it, and CopyResource says nothing when it refuses.
    if (opts.config.blending.isLinear()) {
        log.warn("linear alpha blending is not yet supported by this backend; using native", .{});
    }

    return .{
        .alloc = alloc,
        .blending = .native,
        .device = device,
    };
}

pub fn deinit(self: *D3D11) void {
    self.loopExit();
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
        // Never sRGB: `present` copies this into the back buffer, and CopyResource requires
        // identical formats. See the note in `init`.
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
    if (self.device.swap_chain) |sc| {
        var raw_back: ?*anyopaque = null;
        try api.check("GetBuffer", sc.vt().GetBuffer(
            sc.ptr,
            0,
            @constCast(@ptrCast(&d3d11.com.IID_ID3D11Texture2D)),
            &raw_back,
        ));
        if (api.Texture2D.from(raw_back)) |back| {
            defer back.release();
            ctx.vt().CopyResource(ctx.ptr, back.ptr, target.texture.texture.ptr);
        }
    }
    self.device.dirty = true;
    try self.device.present(false);
    self.last_target = target;
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
