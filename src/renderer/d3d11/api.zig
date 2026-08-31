//! The D3D11 and DXGI entry points, and the small amount of COM machinery above them.
//!
//! Every interface layout, GUID and Windows struct used here comes from `com.zig`, which is
//! generated from pinned Windows metadata. That is a condition of ADR-002's acceptance of this
//! renderer, and it is enforced: `tools/parity/lint_com.py` fails the build on a hand-written
//! vtable or IID anywhere in this directory. Seven slot errors were found in the hand-written
//! harness this replaces, and every one of them compiled, ran and returned S_OK while calling
//! the wrong method.
//!
//! What is written by hand here is only what metadata cannot give: the DLL entry points, which
//! are ordinary exported functions rather than interface methods, and the enum constants. Both
//! fail loudly when wrong -- a missing export does not link, and a wrong constant is rejected
//! by the runtime with an error code -- unlike a vtable slot, which silently calls a neighbour.

const std = @import("std");
const builtin = @import("builtin");
pub const com = @import("com.zig");

const windows = std.os.windows;
pub const HRESULT = windows.HRESULT;
pub const GUID = windows.GUID;

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;

/// Device removal. Distinguished from other failures because the response is different: every
/// device-dependent resource is gone and must be rebuilt, rather than the call being retried.
pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
pub const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));
pub const DXGI_ERROR_DEVICE_HUNG: HRESULT = @bitCast(@as(u32, 0x887A0006));
pub const DXGI_ERROR_DRIVER_INTERNAL_ERROR: HRESULT = @bitCast(@as(u32, 0x887A0020));
pub const DXGI_ERROR_INVALID_CALL: HRESULT = @bitCast(@as(u32, 0x887A0001));

/// Whether an HRESULT means the device is gone rather than the call was wrong.
pub fn isDeviceLost(hr: HRESULT) bool {
    return hr == DXGI_ERROR_DEVICE_REMOVED or
        hr == DXGI_ERROR_DEVICE_RESET or
        hr == DXGI_ERROR_DEVICE_HUNG or
        hr == DXGI_ERROR_DRIVER_INTERNAL_ERROR;
}

pub const Error = error{
    /// The call failed. `last_hresult` carries the code.
    CallFailed,
    /// The adapter is gone; every device-dependent resource must be rebuilt.
    DeviceLost,
    /// No device could be created on any path, hardware or software.
    NoDevice,
    OutOfMemory,
};

/// The HRESULT behind the most recent `Error.CallFailed` on this thread.
///
/// Thread-local because the renderer runs on its own thread while the shell runs on the main
/// one, and a shared last-error lets one thread read the other's failure as its own.
pub threadlocal var last_hresult: HRESULT = S_OK;
pub threadlocal var last_call: []const u8 = "";

/// Turn an HRESULT into a Zig error, remembering what failed.
///
/// Takes the call's name because an HRESULT alone does not say what produced it, and a
/// renderer makes hundreds of these calls per frame. `0x887A0005 somewhere` is not a
/// diagnostic; `0x887A0005 from Present` is.
pub fn check(name: []const u8, hr: HRESULT) Error!void {
    if (hr == S_OK or hr == S_FALSE) return;
    last_hresult = hr;
    last_call = name;
    if (isDeviceLost(hr)) return Error.DeviceLost;
    return Error.CallFailed;
}

// -- entry points ---------------------------------------------------------------------------
//
// Named by API set where one exists. These are exported functions, not interface methods, so
// they are not something metadata describes and not something the COM lint governs.

pub extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*anyopaque,
    driver_type: i32,
    software: ?*anyopaque,
    flags: u32,
    feature_levels: ?[*]const u32,
    feature_level_count: u32,
    sdk_version: u32,
    device: ?*?*anyopaque,
    feature_level: ?*u32,
    context: ?*?*anyopaque,
) callconv(.winapi) HRESULT;

pub extern "dxgi" fn CreateDXGIFactory2(
    flags: u32,
    riid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

pub extern "d3dcompiler_47" fn D3DCompile(
    src: [*]const u8,
    src_len: usize,
    source_name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entry_point: [*:0]const u8,
    target: [*:0]const u8,
    flags1: u32,
    flags2: u32,
    code: *?*anyopaque,
    errors: ?*?*anyopaque,
) callconv(.winapi) HRESULT;

// -- constants ------------------------------------------------------------------------------

pub const D3D11_SDK_VERSION: u32 = 7;

pub const DriverType = struct {
    pub const unknown: i32 = 0;
    pub const hardware: i32 = 1;
    pub const reference: i32 = 2;
    pub const software: i32 = 3;
    pub const warp: i32 = 5;
};

pub const CreateFlag = struct {
    pub const debug: u32 = 0x2;
    /// Required for Direct2D interop, and harmless without it. The renderer is single-threaded
    /// per surface but the swap chain is touched from the main thread on resize.
    pub const bgra_support: u32 = 0x20;
};

pub const FeatureLevel = struct {
    pub const @"11_1": u32 = 0xb100;
    pub const @"11_0": u32 = 0xb000;
    pub const @"10_1": u32 = 0xa100;
    pub const @"10_0": u32 = 0xa000;
};

pub const Format = struct {
    pub const unknown: i32 = 0;
    pub const r8g8b8a8_unorm: i32 = 28;
    pub const r8g8b8a8_unorm_srgb: i32 = 29;
    pub const b8g8r8a8_unorm: i32 = 87;
    pub const b8g8r8a8_unorm_srgb: i32 = 91;
    pub const r8_unorm: i32 = 61;
    pub const r32g32_float: i32 = 16;
    pub const r32g32b32a32_float: i32 = 2;
    pub const r32_uint: i32 = 42;
};

pub const Usage = struct {
    pub const default: i32 = 0;
    pub const immutable: i32 = 1;
    pub const dynamic: i32 = 2;
    pub const staging: i32 = 3;
};

pub const Bind = struct {
    pub const vertex_buffer: u32 = 0x1;
    pub const index_buffer: u32 = 0x2;
    pub const constant_buffer: u32 = 0x4;
    pub const shader_resource: u32 = 0x8;
    pub const render_target: u32 = 0x20;
};

pub const CpuAccess = struct {
    pub const write: u32 = 0x10000;
    pub const read: u32 = 0x20000;
};

pub const Map = struct {
    pub const read: i32 = 1;
    pub const write: i32 = 2;
    pub const read_write: i32 = 3;
    pub const write_discard: i32 = 4;
    pub const write_no_overwrite: i32 = 5;
};

pub const SwapEffect = struct {
    pub const discard: i32 = 0;
    pub const sequential: i32 = 1;
    pub const flip_sequential: i32 = 3;
    pub const flip_discard: i32 = 4;
};

pub const AlphaMode = struct {
    pub const unspecified: i32 = 0;
    pub const premultiplied: i32 = 2;
    pub const ignore: i32 = 3;
};

pub const Scaling = struct {
    pub const stretch: i32 = 0;
    pub const none: i32 = 1;
    pub const aspect_ratio_stretch: i32 = 2;
};

pub const usage_render_target_output: u32 = 0x20;

pub const Topology = struct {
    pub const triangle_list: u32 = 4;
    pub const triangle_strip: u32 = 5;
};

/// Blend factors and ops, for the premultiplied-alpha blend the text pass uses.
pub const Blend = struct {
    pub const zero: i32 = 1;
    pub const one: i32 = 2;
    pub const src_alpha: i32 = 5;
    pub const inv_src_alpha: i32 = 6;
    pub const src1_color: i32 = 16;
    pub const inv_src1_color: i32 = 17;
};

pub const BlendOp = struct {
    pub const add: i32 = 1;
};

pub const color_write_enable_all: u8 = 0x0F;

pub const Filter = struct {
    pub const min_mag_mip_point: i32 = 0;
    pub const min_mag_mip_linear: i32 = 0x15;
};

pub const TextureAddress = struct {
    pub const wrap: i32 = 1;
    pub const clamp: i32 = 3;
};

pub const Cull = struct {
    pub const none: i32 = 1;
    pub const front: i32 = 2;
    pub const back: i32 = 3;
};

pub const Fill = struct {
    pub const wireframe: i32 = 2;
    pub const solid: i32 = 3;
};

// -- COM helpers ----------------------------------------------------------------------------

/// A reference-counted interface pointer.
///
/// The cast from `*anyopaque` to a vtable is the one operation here with no type safety at
/// all: at runtime an interface pointer is a pointer to a pointer to an array of function
/// pointers, and nothing distinguishes one interface from another. Confining the cast to this
/// type means there is one place to be careful rather than one per call.
pub fn Interface(comptime V: type) type {
    return struct {
        const Self = @This();
        ptr: *anyopaque,

        pub fn from(raw: ?*anyopaque) ?Self {
            return .{ .ptr = raw orelse return null };
        }

        pub inline fn vt(self: Self) *const V {
            return @as(*const *const V, @ptrCast(@alignCast(self.ptr))).*;
        }

        pub inline fn unknown(self: Self) *const com.IUnknownVtbl {
            return @ptrCast(self.vt());
        }

        pub fn addRef(self: Self) void {
            _ = self.unknown().AddRef(self.ptr);
        }

        pub fn release(self: Self) void {
            _ = self.unknown().Release(self.ptr);
        }

        /// QueryInterface, returning the requested interface or an error.
        pub fn queryInterface(
            self: Self,
            iid: *const GUID,
            comptime W: type,
        ) Error!Interface(W) {
            var out: ?*anyopaque = null;
            try check("QueryInterface", self.unknown().QueryInterface(self.ptr, iid, &out));
            return .{ .ptr = out orelse return Error.CallFailed };
        }
    };
}

pub const Device = Interface(com.ID3D11DeviceVtbl);
pub const Context = Interface(com.ID3D11DeviceContextVtbl);
pub const SwapChain = Interface(com.IDXGISwapChain1Vtbl);
pub const Factory = Interface(com.IDXGIFactory2Vtbl);
pub const Texture2D = Interface(com.ID3D11Texture2DVtbl);
pub const RenderTargetView = Interface(com.ID3D11RenderTargetViewVtbl);
pub const ShaderResourceView = Interface(com.ID3D11ShaderResourceViewVtbl);
pub const Buffer = Interface(com.ID3D11BufferVtbl);
pub const VertexShader = Interface(com.ID3D11VertexShaderVtbl);
pub const PixelShader = Interface(com.ID3D11PixelShaderVtbl);
pub const InputLayout = Interface(com.ID3D11InputLayoutVtbl);
pub const SamplerState = Interface(com.ID3D11SamplerStateVtbl);
pub const BlendState = Interface(com.ID3D11BlendStateVtbl);
pub const RasterizerState = Interface(com.ID3D11RasterizerStateVtbl);
pub const Blob = Interface(com.ID3DBlobVtbl);
pub const InfoQueue = Interface(com.ID3D11InfoQueueVtbl);
pub const DxgiDevice = Interface(com.IDXGIDeviceVtbl);
pub const DxgiAdapter = Interface(com.IDXGIAdapterVtbl);
