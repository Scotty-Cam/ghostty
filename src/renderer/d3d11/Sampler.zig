//! A sampler state.

const std = @import("std");
const api = @import("api.zig");
const com = api.com;

const Self = @This();

pub const Filter = enum { nearest, linear };
pub const Wrap = enum { clamp, repeat };

pub const Options = struct {
    filter: Filter = .linear,
    wrap: Wrap = .clamp,
    device: api.Device,
};

pub const Error = api.Error;

sampler: api.SamplerState,

pub fn init(opts: Options) Error!Self {
    var desc = com.D3D11_SAMPLER_DESC{
        .Filter = switch (opts.filter) {
            .nearest => api.Filter.min_mag_mip_point,
            .linear => api.Filter.min_mag_mip_linear,
        },
        .AddressU = switch (opts.wrap) {
            .clamp => api.TextureAddress.clamp,
            .repeat => api.TextureAddress.wrap,
        },
        .AddressV = switch (opts.wrap) {
            .clamp => api.TextureAddress.clamp,
            .repeat => api.TextureAddress.wrap,
        },
        .AddressW = api.TextureAddress.clamp,
        .MipLODBias = 0,
        .MaxAnisotropy = 1,
        .ComparisonFunc = 1, // NEVER
        .BorderColor = .{ 0, 0, 0, 0 },
        .MinLOD = 0,
        .MaxLOD = 0,
    };
    var raw: ?*anyopaque = null;
    try api.check("CreateSamplerState", opts.device.vt().CreateSamplerState(
        opts.device.ptr,
        &desc,
        &raw,
    ));
    return .{ .sampler = api.SamplerState.from(raw) orelse return Error.CallFailed };
}

pub fn deinit(self: Self) void {
    self.sampler.release();
}
