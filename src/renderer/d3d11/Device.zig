//! The D3D11 device, its immediate context, and the swap chain bound to a window.
//!
//! Creation is explicit at every step, which ADR-002 requires and which is not the same as
//! being verbose for its own sake. `D3D11CreateDevice` with a null adapter and an unknown
//! driver type will pick something on almost any machine, including a software adapter, and
//! report success either way -- so a renderer that does not ask which one it got cannot tell a
//! hardware path from a fallback, and neither can anyone reading its logs.

const std = @import("std");
/// Re-exported so a consumer reaches the entry points and error detail through the device
/// rather than importing the same file as a second module root, which Zig rejects outright.
pub const api = @import("api.zig");
const com = api.com;

const Device = @This();
const log = std.log.scoped(.d3d11);

/// Which adapter the device was actually created on.
///
/// Recorded rather than inferred. ADR-002 requires a software fallback *and* requires that
/// falling back is visible: a terminal quietly running on WARP is a terminal that will miss
/// its frame budget for reasons nobody can see.
pub const Driver = enum { hardware, warp };

device: api.Device,
context: api.Context,
driver: Driver,
feature_level: u32,
/// Null until a window is attached.
swap_chain: ?api.SwapChain = null,
/// The back buffer's view, rebuilt on every resize and after device loss.
rtv: ?api.RenderTargetView = null,
width: u32 = 0,
height: u32 = 0,
/// Present only when something changed, per ADR-002.
dirty: bool = true,

/// The feature levels we accept, best first.
///
/// 11_0 is the floor because the cell shader needs nothing above it, and a floor higher than
/// the work requires excludes machines for no benefit. The Surface this is developed against
/// reports 12_1, which says nothing about the machines it has to run on.
const feature_levels = [_]u32{
    api.FeatureLevel.@"11_1",
    api.FeatureLevel.@"11_0",
};

/// Create a device, preferring hardware and falling back to WARP.
///
/// `debug_layer` is requested, not required: the D3D11 debug layer is an optional Windows
/// component and is absent on a stock install. Asking for it on a machine without it fails
/// device creation outright, so a failure with the flag is retried without it rather than
/// reported as no device -- which is what the reference machine does, and why its
/// diagnosability is recorded as unmeasured rather than assumed.
pub fn init(debug_layer: bool) api.Error!Device {
    var flags: u32 = api.CreateFlag.bgra_support;
    if (debug_layer) flags |= api.CreateFlag.debug;

    if (create(api.DriverType.hardware, flags)) |d| return d else |_| {}
    if (debug_layer) {
        // Retry without the debug layer before giving up on hardware: its absence is the
        // common cause and it is not worth losing the hardware path over.
        if (create(api.DriverType.hardware, api.CreateFlag.bgra_support)) |d| {
            log.warn("D3D11 debug layer unavailable; continuing without it", .{});
            return d;
        } else |_| {}
    }

    log.warn("no hardware D3D11 device; falling back to WARP", .{});
    if (create(api.DriverType.warp, api.CreateFlag.bgra_support)) |d| return d else |_| {}
    return api.Error.NoDevice;
}

fn create(driver_type: i32, flags: u32) api.Error!Device {
    var raw_device: ?*anyopaque = null;
    var raw_context: ?*anyopaque = null;
    var level: u32 = 0;

    try api.check("D3D11CreateDevice", api.D3D11CreateDevice(
        null,
        driver_type,
        null,
        flags,
        &feature_levels,
        feature_levels.len,
        api.D3D11_SDK_VERSION,
        &raw_device,
        &level,
        &raw_context,
    ));

    const device = api.Device.from(raw_device) orelse return api.Error.NoDevice;
    const context = api.Context.from(raw_context) orelse {
        device.release();
        return api.Error.NoDevice;
    };

    return .{
        .device = device,
        .context = context,
        .driver = if (driver_type == api.DriverType.warp) .warp else .hardware,
        .feature_level = level,
    };
}

/// Rebuild the device and its swap chain after the adapter has gone.
///
/// Everything the old device made is invalid, including the device itself, so this is a
/// destroy and a create rather than a repair -- `ResizeBuffers` and friends cannot bring a
/// removed device back.
///
/// The caller must have released every other object created from the old device FIRST. Nothing
/// here can check that: a COM interface from a removed device still answers `Release`, so a
/// missed one is not a crash but a leak, and the object-count oracle is what catches it.
///
/// `ClearState` and `Flush` before tearing down, because D3D11 holds references from bound
/// pipeline slots and defers destruction otherwise -- so a teardown without them frees nothing
/// at the moment it appears to, which the same oracle would read as a leak.
pub fn rebuild(
    self: *Device,
    hwnd: ?*anyopaque,
    width: u32,
    height: u32,
    debug_layer: bool,
) api.Error!void {
    self.context.vt().ClearState(self.context.ptr);
    self.context.vt().Flush(self.context.ptr);
    self.deinit();

    self.* = try Device.init(debug_layer);
    errdefer self.deinit();
    try self.attach(hwnd, width, height);
    // The new back buffer holds nothing, so the next frame must be presented even if the
    // terminal has not changed a cell.
    self.dirty = true;
}

pub fn deinit(self: *Device) void {
    self.releaseTargets();
    if (self.swap_chain) |sc| sc.release();
    self.context.release();
    self.device.release();
    self.* = undefined;
}

fn releaseTargets(self: *Device) void {
    if (self.rtv) |v| {
        v.release();
        self.rtv = null;
    }
}

/// Attach a swap chain to a window.
///
/// Flip-model with two buffers. The older blit model is not a style choice to avoid: on a
/// composited desktop it costs an extra copy of every frame, and the flip model is what makes
/// present-on-change worth doing at all.
pub fn attach(self: *Device, hwnd: ?*anyopaque, width: u32, height: u32) api.Error!void {
    if (self.swap_chain != null) return;

    // The factory is reached through the device's own adapter rather than created fresh.
    // A swap chain made by an unrelated factory is not necessarily on the same adapter as the
    // device, which produces a chain that fails to present rather than failing to create.
    const dxgi_device = try self.device.queryInterface(&com.IID_IDXGIDevice, com.IDXGIDeviceVtbl);
    defer dxgi_device.release();

    var raw_adapter: ?*anyopaque = null;
    try api.check("GetAdapter", dxgi_device.vt().GetAdapter(dxgi_device.ptr, &raw_adapter));
    const adapter = api.DxgiAdapter.from(raw_adapter) orelse return api.Error.CallFailed;
    defer adapter.release();

    var raw_factory: ?*anyopaque = null;
    // The generator flattens an interface's inherited methods into one vtable, so GetParent
    // -- declared on IDXGIObject -- is a field of IDXGIAdapterVtbl rather than something
    // reached through a nested base. Writing it as `.base.base.GetParent` did not compile,
    // which is the generated bindings doing their job: hand-written, that mistake would have
    // been a call through whatever pointer happened to sit at that offset.
    try api.check("GetParent", adapter.vt().GetParent(
        adapter.ptr,
        @constCast(@ptrCast(&com.IID_IDXGIFactory2)),
        &raw_factory,
    ));
    const factory = api.Factory.from(raw_factory) orelse return api.Error.CallFailed;
    defer factory.release();

    var desc = com.DXGI_SWAP_CHAIN_DESC1{
        .Width = @max(width, 1),
        .Height = @max(height, 1),
        .Format = api.Format.b8g8r8a8_unorm,
        .Stereo = 0,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = api.usage_render_target_output,
        .BufferCount = 2,
        .Scaling = api.Scaling.none,
        .SwapEffect = api.SwapEffect.flip_discard,
        .AlphaMode = api.AlphaMode.ignore,
        .Flags = 0,
    };

    var raw_chain: ?*anyopaque = null;
    try api.check("CreateSwapChainForHwnd", factory.vt().CreateSwapChainForHwnd(
        factory.ptr,
        self.device.ptr,
        hwnd,
        &desc,
        null,
        null,
        &raw_chain,
    ));
    self.swap_chain = api.SwapChain.from(raw_chain) orelse return api.Error.CallFailed;
    self.width = desc.Width;
    self.height = desc.Height;
    try self.buildTargets();
}

/// Build the render-target view over the current back buffer.
fn buildTargets(self: *Device) api.Error!void {
    const sc = self.swap_chain orelse return api.Error.CallFailed;
    self.releaseTargets();

    var raw_back: ?*anyopaque = null;
    try api.check("GetBuffer", sc.vt().GetBuffer(
        sc.ptr,
        0,
        @constCast(@ptrCast(&com.IID_ID3D11Texture2D)),
        &raw_back,
    ));
    const back = api.Texture2D.from(raw_back) orelse return api.Error.CallFailed;
    defer back.release();

    var raw_rtv: ?*anyopaque = null;
    try api.check("CreateRenderTargetView", self.device.vt().CreateRenderTargetView(
        self.device.ptr,
        back.ptr,
        null,
        &raw_rtv,
    ));
    self.rtv = api.RenderTargetView.from(raw_rtv) orelse return api.Error.CallFailed;
    self.dirty = true;
}

/// Resize the swap chain. A no-op when the size has not changed.
///
/// The views are released first because ResizeBuffers fails while any reference to a back
/// buffer is outstanding -- and it fails with a generic invalid-call code that says nothing
/// about which reference is holding it.
pub fn resize(self: *Device, width: u32, height: u32) api.Error!void {
    const w = @max(width, 1);
    const h = @max(height, 1);
    if (w == self.width and h == self.height) return;
    const sc = self.swap_chain orelse return;

    self.releaseTargets();
    try api.check("ResizeBuffers", sc.vt().ResizeBuffers(sc.ptr, 0, w, h, api.Format.unknown, 0));
    self.width = w;
    self.height = h;
    try self.buildTargets();
}

/// Present, but only when something has changed.
///
/// ADR-002 asks for present-on-change. A terminal is idle most of the time, and presenting an
/// unchanged frame costs a composition pass and, on a laptop, measurable battery for a picture
/// nobody can tell from the last one.
pub fn present(self: *Device, force: bool) api.Error!void {
    if (!self.dirty and !force) return;
    const sc = self.swap_chain orelse return;
    // Sync interval 1: vsync. Tearing needs a flag on both the chain and the present, and is
    // not something a terminal benefits from.
    try api.check("Present", sc.vt().Present(sc.ptr, 1, 0));
    self.dirty = false;
}
