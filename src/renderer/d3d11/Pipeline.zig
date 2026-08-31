//! A compiled shader pair, its input layout and its blend state.
//!
//! The input layout is derived from the Zig vertex-attribute struct, the same way the OpenGL
//! backend derives its vertex array format. That is not a convenience: the alternative is a
//! hand-written element list per pipeline that has to agree with a struct it does not mention,
//! and the failure when they disagree is a shader reading a neighbouring field's bytes -- which
//! draws something, so it is not obviously broken.

const std = @import("std");
const api = @import("api.zig");
const com = api.com;

const Self = @This();
const log = std.log.scoped(.d3d11);

pub const Options = struct {
    /// HLSL source. Compiled here rather than offline so a custom shader takes the same path
    /// as a built-in one.
    source: [:0]const u8,
    /// A name for diagnostics; D3DCompile reports errors against it.
    name: [:0]const u8,
    vertex_entry: [:0]const u8 = "vs_main",
    pixel_entry: [:0]const u8 = "ps_main",
    step_fn: StepFunction = .per_vertex,
    blending_enabled: bool = true,
    device: api.Device,

    pub const StepFunction = enum { constant, per_vertex, per_instance };
};

vs: api.VertexShader,
ps: api.PixelShader,
layout: ?api.InputLayout,
blend: ?api.BlendState,
stride: u32,
blending_enabled: bool,

/// Map a Zig attribute field to a DXGI format.
///
/// Integer attributes stay integers. The OpenGL backend is careful to use the `I` form of the
/// attribute functions for them, and the equivalent mistake here is a UNORM format, which would
/// hand the shader 1/255th of every colour and a glyph position of nearly zero.
fn dxgiFormat(comptime T: type) i32 {
    const FT = switch (@typeInfo(T)) {
        .@"struct" => |s| s.backing_integer.?,
        .@"enum" => |e| e.tag_type,
        else => T,
    };
    const count, const Elem = switch (@typeInfo(FT)) {
        .array => |a| .{ a.len, a.child },
        else => .{ 1, FT },
    };
    const F = Dxgi;
    return switch (Elem) {
        u8 => switch (count) { 1 => F.r8_uint, 2 => F.r8g8_uint, 4 => F.r8g8b8a8_uint, else => @compileError("unsupported u8 count") },
        i8 => switch (count) { 1 => F.r8_sint, 2 => F.r8g8_sint, 4 => F.r8g8b8a8_sint, else => @compileError("unsupported i8 count") },
        u16 => switch (count) { 1 => F.r16_uint, 2 => F.r16g16_uint, 4 => F.r16g16b16a16_uint, else => @compileError("unsupported u16 count") },
        i16 => switch (count) { 1 => F.r16_sint, 2 => F.r16g16_sint, 4 => F.r16g16b16a16_sint, else => @compileError("unsupported i16 count") },
        u32 => switch (count) { 1 => F.r32_uint, 2 => F.r32g32_uint, 3 => F.r32g32b32_uint, 4 => F.r32g32b32a32_uint, else => @compileError("unsupported u32 count") },
        i32 => switch (count) { 1 => F.r32_sint, 2 => F.r32g32_sint, 4 => F.r32g32b32a32_sint, else => @compileError("unsupported i32 count") },
        f32 => switch (count) { 1 => F.r32_float, 2 => F.r32g32_float, 3 => F.r32g32b32_float, 4 => F.r32g32b32a32_float, else => @compileError("unsupported f32 count") },
        else => @compileError("unsupported attribute element type " ++ @typeName(Elem)),
    };
}

/// The DXGI_FORMAT values this backend uses, named.
///
/// Transcribed from the pinned SDK's dxgiformat.h and asserted against it by
/// `tools/parity/dxgi_formats.py`, because the first version of the table above was written
/// from memory and six of its fifteen entries were wrong -- R8_UINT as 30, R32G32_UINT as 36,
/// R16G16B16A16_SINT as 17. None of them would have failed to compile or to create a pipeline.
/// The shader would simply have read its attributes from the wrong widths at the wrong offsets
/// and drawn something, which is the hardest kind of wrong to see.
///
/// The enum is not in the generated bindings because the generator resolves an enum to its
/// underlying integer type rather than emitting its members, so there is nothing to import.
pub const Dxgi = struct {
    pub const r32g32b32a32_float: i32 = 2;
    pub const r32g32b32a32_uint: i32 = 3;
    pub const r32g32b32a32_sint: i32 = 4;
    pub const r32g32b32_float: i32 = 6;
    pub const r32g32b32_uint: i32 = 7;
    pub const r16g16b16a16_uint: i32 = 12;
    pub const r16g16b16a16_sint: i32 = 14;
    pub const r32g32_float: i32 = 16;
    pub const r32g32_uint: i32 = 17;
    pub const r32g32_sint: i32 = 18;
    pub const r8g8b8a8_uint: i32 = 30;
    pub const r8g8b8a8_sint: i32 = 32;
    pub const r16g16_uint: i32 = 36;
    pub const r16g16_sint: i32 = 38;
    pub const r32_float: i32 = 41;
    pub const r32_uint: i32 = 42;
    pub const r32_sint: i32 = 43;
    pub const r8g8_uint: i32 = 50;
    pub const r8g8_sint: i32 = 52;
    pub const r16_uint: i32 = 57;
    pub const r16_sint: i32 = 59;
    pub const r8_uint: i32 = 62;
    pub const r8_sint: i32 = 64;
};

/// The HLSL semantic for a field, which is its name upper-cased.
///
/// A rule rather than a table, so a renamed field is a link error at pipeline creation rather
/// than a silent mismatch: D3D11 binds vertex inputs by semantic name, and an element the
/// shader does not declare is simply not fed.
fn semanticName(comptime name: []const u8) [:0]const u8 {
    return comptime blk: {
        var buf: [name.len:0]u8 = @splat(0);
        for (name, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        const final = buf;
        break :blk &final;
    };
}

fn compile(opts: Options, entry: [:0]const u8, target: [:0]const u8) api.Error!api.Blob {
    var code: ?*anyopaque = null;
    var errors: ?*anyopaque = null;
    const hr = api.D3DCompile(
        opts.source.ptr,
        opts.source.len,
        opts.name.ptr,
        null,
        null,
        entry.ptr,
        target.ptr,
        0,
        0,
        &code,
        &errors,
    );
    if (hr != api.S_OK) {
        // The compiler's own message, which names the line and the reason. Without it a
        // failure here is an HRESULT and a guess.
        if (api.Blob.from(errors)) |e| {
            defer e.release();
            if (e.vt().GetBufferPointer(e.ptr)) |raw| {
                const ptr: [*]const u8 = @ptrCast(raw);
                const len = e.vt().GetBufferSize(e.ptr);
                log.err("{s} {s}: {s}", .{ opts.name, entry, ptr[0..len] });
            }
        }
        api.last_hresult = hr;
        api.last_call = "D3DCompile";
        return api.Error.CallFailed;
    }
    if (api.Blob.from(errors)) |e| e.release();
    return api.Blob.from(code) orelse api.Error.CallFailed;
}

pub fn init(comptime VertexAttributes: ?type, opts: Options) api.Error!Self {
    const vs_blob = try compile(opts, opts.vertex_entry, "vs_5_0");
    defer vs_blob.release();
    const ps_blob = try compile(opts, opts.pixel_entry, "ps_5_0");
    defer ps_blob.release();

    const dev = opts.device;

    const vs_code = vs_blob.vt().GetBufferPointer(vs_blob.ptr);
    const vs_size = vs_blob.vt().GetBufferSize(vs_blob.ptr);
    var raw_vs: ?*anyopaque = null;
    try api.check("CreateVertexShader", dev.vt().CreateVertexShader(
        dev.ptr,
        vs_code,
        vs_size,
        null,
        &raw_vs,
    ));
    const vs = api.VertexShader.from(raw_vs) orelse return api.Error.CallFailed;
    errdefer vs.release();

    var raw_ps: ?*anyopaque = null;
    try api.check("CreatePixelShader", dev.vt().CreatePixelShader(
        dev.ptr,
        ps_blob.vt().GetBufferPointer(ps_blob.ptr),
        ps_blob.vt().GetBufferSize(ps_blob.ptr),
        null,
        &raw_ps,
    ));
    const ps = api.PixelShader.from(raw_ps) orelse return api.Error.CallFailed;
    errdefer ps.release();

    var layout: ?api.InputLayout = null;
    var stride: u32 = 0;
    if (VertexAttributes) |VA| {
        const fields = @typeInfo(VA).@"struct".fields;
        var elems: [fields.len]com.D3D11_INPUT_ELEMENT_DESC = undefined;
        inline for (fields, 0..) |f, i| {
            elems[i] = .{
                // The metadata types this as a mutable pointer, because the C declaration is
                // not const-correct. D3D11 does not write to it.
                .SemanticName = @constCast(semanticName(f.name).ptr),
                .SemanticIndex = 0,
                .Format = dxgiFormat(f.type),
                .InputSlot = 0,
                .AlignedByteOffset = @offsetOf(VA, f.name),
                .InputSlotClass = switch (opts.step_fn) {
                    .per_vertex, .constant => 0,
                    .per_instance => 1,
                },
                .InstanceDataStepRate = switch (opts.step_fn) {
                    .per_vertex, .constant => 0,
                    .per_instance => 1,
                },
            };
        }
        var raw_layout: ?*anyopaque = null;
        try api.check("CreateInputLayout", dev.vt().CreateInputLayout(
            dev.ptr,
            // &elems[0], not &elems: the metadata declares a pointer to one element and
            // a count, which is the C convention. A pointer to the array has the same
            // address and the wrong type.
            &elems[0],
            elems.len,
            vs_code,
            vs_size,
            &raw_layout,
        ));
        layout = api.InputLayout.from(raw_layout) orelse return api.Error.CallFailed;
        stride = @sizeOf(VA);
    }
    errdefer if (layout) |l| l.release();

    var blend: ?api.BlendState = null;
    if (opts.blending_enabled) {
        var desc = std.mem.zeroes(com.D3D11_BLEND_DESC);
        desc.RenderTarget[0] = .{
            .BlendEnable = 1,
            // Premultiplied alpha: ONE / INV_SRC_ALPHA. Every colour reaching the blender has
            // already been multiplied by its own alpha, in load_color and again by the glyph
            // mask, so SRC_ALPHA here would apply it a second time and thin every glyph.
            .SrcBlend = api.Blend.one,
            .DestBlend = api.Blend.inv_src_alpha,
            .BlendOp = api.BlendOp.add,
            .SrcBlendAlpha = api.Blend.one,
            .DestBlendAlpha = api.Blend.inv_src_alpha,
            .BlendOpAlpha = api.BlendOp.add,
            .RenderTargetWriteMask = api.color_write_enable_all,
        };
        var raw_blend: ?*anyopaque = null;
        try api.check("CreateBlendState", dev.vt().CreateBlendState(dev.ptr, &desc, &raw_blend));
        blend = api.BlendState.from(raw_blend) orelse return api.Error.CallFailed;
    }

    return .{
        .vs = vs,
        .ps = ps,
        .layout = layout,
        .blend = blend,
        .stride = stride,
        .blending_enabled = opts.blending_enabled,
    };
}

pub fn deinit(self: *const Self) void {
    if (self.blend) |b| b.release();
    if (self.layout) |l| l.release();
    self.ps.release();
    self.vs.release();
}
