//! A 2D texture and its shader-resource view.
//!
//! D3D11 separates the resource from the way a shader sees it, so a texture here is both: the
//! generic renderer hands textures straight to a render pass, and a resource with no view is
//! not something that can be sampled.

const std = @import("std");
const api = @import("api.zig");
const com = api.com;

const Self = @This();

/// The pixel formats the renderer actually asks for.
///
/// A named set rather than the raw DXGI enum, because the atlas formats and the image formats
/// are the only ones that occur and spelling them out is what makes a mismatch a compile error
/// rather than a wrong number.
pub const Format = enum {
    /// Single channel, 8 bit. Grayscale glyph coverage.
    r8,
    /// Four channel, 8 bit, BGRA order. Colour glyphs and images.
    bgra8,
    /// As bgra8, sampled as sRGB.
    bgra8_srgb,
    /// Four channel, 8 bit, RGBA order.
    rgba8,

    pub fn dxgi(self: Format) i32 {
        return switch (self) {
            .r8 => api.Format.r8_unorm,
            .bgra8 => api.Format.b8g8r8a8_unorm,
            .bgra8_srgb => api.Format.b8g8r8a8_unorm_srgb,
            .rgba8 => api.Format.r8g8b8a8_unorm,
        };
    }

    pub fn bytesPerPixel(self: Format) usize {
        return switch (self) {
            .r8 => 1,
            .bgra8, .bgra8_srgb, .rgba8 => 4,
        };
    }
};

pub const Options = struct {
    format: Format = .bgra8,
    /// Whether the texture is also a render target. The post-processing chain renders into
    /// textures, so this is not a rare case.
    render_target: bool = false,
    /// Whether the render-target view gamma-encodes on write.
    ///
    /// The *view* and not the resource. A view may use a different format from the resource it
    /// is over, so long as both are in the same family -- and that is what makes linear
    /// blending possible without changing the resource: the GPU blends linearly and encodes on
    /// write, while the texture stays UNORM and can still be copied to the swap chain.
    ///
    /// Creating the resource itself as `_SRGB` also works and renders correctly, and then
    /// `CopyResource` into a UNORM back buffer fails -- silently, because it returns void and
    /// only the debug layer says a word. The window kept showing the frame before it.
    render_target_srgb: bool = false,
    /// D3D11 resources are created by a device and updated through a context, and the generic
    /// renderer constructs textures from `textureOptions()` with neither in hand -- so both
    /// travel in the options, as they do for samplers and buffers. The alternative is an
    /// `init` with a different arity from every other backend's, which does not fit the
    /// contract the generic renderer calls through.
    device: api.Device,
    context: api.Context,
};

pub const Error = api.Error;

texture: api.Texture2D,
srv: api.ShaderResourceView,
/// Present only for a render-target texture.
rtv: ?api.RenderTargetView = null,
width: usize,
height: usize,
format: Format,
/// Held so `replaceRegion` matches the other backends' signature, which takes no context.
context: api.Context,

pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const device = opts.device;
    var bind: u32 = api.Bind.shader_resource;
    if (opts.render_target) bind |= api.Bind.render_target;

    var desc = com.D3D11_TEXTURE2D_DESC{
        .Width = @intCast(width),
        .Height = @intCast(height),
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.format.dxgi(),
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        // DEFAULT with UpdateSubresource rather than DYNAMIC with Map.
        //
        // The atlas is written in rectangles as glyphs are rasterised, and DYNAMIC textures
        // can only be mapped with WRITE_DISCARD, which throws away everything already in the
        // atlas. That is correct for a buffer rewritten every frame and wrong for a texture
        // that accumulates.
        .Usage = api.Usage.default,
        .BindFlags = bind,
        .CPUAccessFlags = 0,
        .MiscFlags = 0,
    };

    const bpp = opts.format.bytesPerPixel();
    var initial: com.D3D11_SUBRESOURCE_DATA = undefined;
    var initial_ptr: ?*com.D3D11_SUBRESOURCE_DATA = null;
    if (data) |d| {
        initial = .{
            .pSysMem = @constCast(@ptrCast(d.ptr)),
            .SysMemPitch = @intCast(width * bpp),
            .SysMemSlicePitch = 0,
        };
        initial_ptr = &initial;
    }

    var raw: ?*anyopaque = null;
    try api.check("CreateTexture2D", device.vt().CreateTexture2D(
        device.ptr,
        &desc,
        @ptrCast(initial_ptr),
        &raw,
    ));
    const texture = api.Texture2D.from(raw) orelse return Error.CallFailed;
    errdefer texture.release();

    var raw_srv: ?*anyopaque = null;
    try api.check("CreateShaderResourceView", device.vt().CreateShaderResourceView(
        device.ptr,
        texture.ptr,
        null,
        &raw_srv,
    ));
    const srv = api.ShaderResourceView.from(raw_srv) orelse return Error.CallFailed;
    errdefer srv.release();

    var rtv: ?api.RenderTargetView = null;
    if (opts.render_target) {
            var raw_rtv: ?*anyopaque = null;
        // A described view when it must gamma-encode, the resource's own format otherwise.
        // The descriptor cannot be built from the generated bindings -- D3D11_RENDER_TARGET_VIEW_DESC
        // carries an anonymous union the metadata cannot name -- so the sRGB case is expressed
        // by creating the resource in the sRGB format instead, and the copy in `present` is
        // what has to tolerate it.
        try api.check("CreateRenderTargetView", device.vt().CreateRenderTargetView(
            device.ptr,
            texture.ptr,
            null,
            &raw_rtv,
        ));
        rtv = api.RenderTargetView.from(raw_rtv) orelse return Error.CallFailed;
    }

    return .{
        .texture = texture,
        .srv = srv,
        .rtv = rtv,
        .width = width,
        .height = height,
        .format = opts.format,
        .context = opts.context,
    };
}

pub fn deinit(self: Self) void {
    if (self.rtv) |v| v.release();
    self.srv.release();
    self.texture.release();
}

/// Take a reference to every interface this texture holds.
///
/// A `Texture` is a value type holding three raw COM pointers, so copying one copies the
/// pointers and NOT the references -- and then two copies each call `deinit`, releasing the
/// same interfaces twice. `retain` is what makes a copy legitimate, and it exists as the
/// mirror of `deinit` so a reader can see they are a pair.
pub fn retain(self: Self) void {
    self.texture.addRef();
    self.srv.addRef();
    if (self.rtv) |v| v.addRef();
}

/// Replace a rectangle of the texture.
///
/// The row pitch is the *source* pitch, which is the region's width and not the texture's.
/// Passing the texture's width silently reads the wrong bytes for every row after the first,
/// which looks like a corrupt atlas rather than a wrong number.
pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    const bpp = self.format.bytesPerPixel();
    var box = com.D3D11_BOX{
        .left = @intCast(x),
        .top = @intCast(y),
        .front = 0,
        .right = @intCast(x + width),
        .bottom = @intCast(y + height),
        .back = 1,
    };
    self.context.vt().UpdateSubresource(
        self.context.ptr,
        self.texture.ptr,
        0,
        &box,
        @constCast(@ptrCast(data.ptr)),
        @intCast(width * bpp),
        0,
    );
}
