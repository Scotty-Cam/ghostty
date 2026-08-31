//! Typed GPU buffers.
//!
//! Mirrors the OpenGL backend's `Buffer(T)`: preallocate, sync whole contents, grow by
//! doubling when the contents outgrow the allocation. The generic renderer drives all of it,
//! so the shape is not ours to choose.

const std = @import("std");
const api = @import("api.zig");
const com = api.com;

pub const Kind = enum {
    vertex,
    constant,
    /// A StructuredBuffer read through a shader-resource view.
    ///
    /// This is what the generic renderer calls a storage buffer. D3D11 has no
    /// shader-storage-buffer equivalent, and a constant buffer cannot hold a grid of cells --
    /// the limit is 4096 float4s, which a 200x50 grid passes. A structured buffer is the shape
    /// that fits, and it needs an SRV, which is why this kind carries one and the others do not.
    structured,

    fn bindFlag(self: Kind) u32 {
        return switch (self) {
            .vertex => api.Bind.vertex_buffer,
            .constant => api.Bind.constant_buffer,
            .structured => api.Bind.shader_resource,
        };
    }
};

/// D3D11_RESOURCE_MISC_BUFFER_STRUCTURED.
const misc_structured: u32 = 0x40;

/// A buffer as everything outside this file sees it.
///
/// The resource and its shader-resource view together, because the generic renderer hands a
/// render pass `someBuffer.buffer` and the pass needs both: a structured buffer is bound
/// through its view and a vertex buffer through the resource. Splitting them would mean the
/// pass taking a second parallel list and keeping the two in step by hand.
pub const Handle = struct {
    resource: api.Buffer,
    /// Present only for a structured buffer.
    srv: ?api.ShaderResourceView = null,

    pub fn release(self: Handle) void {
        if (self.srv) |v| v.release();
        self.resource.release();
    }
};

pub const Options = struct {
    kind: Kind = .vertex,
    /// The device is carried in the options because D3D11 resources are created by a device
    /// rather than by a bound global, and the generic renderer constructs buffers through
    /// `bufferOptions()` without a device in hand.
    device: api.Device,
    context: api.Context,
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: Handle,
        opts: Options,
        /// Capacity in elements, not bytes.
        len: usize,

        /// A constant buffer's size must be a multiple of 16 bytes, and D3D11 rejects the
        /// creation outright otherwise. Rounding here rather than at every call site is what
        /// stops that being rediscovered per buffer type.
        fn byteSize(kind: Kind, count: usize) u32 {
            const raw = @max(count * @sizeOf(T), @sizeOf(T));
            return @intCast(switch (kind) {
                .constant => std.mem.alignForward(usize, raw, 16),
                .vertex, .structured => raw,
            });
        }

        fn create(opts: Options, count: usize, data: ?[*]const u8) api.Error!api.Buffer {
            var desc = com.D3D11_BUFFER_DESC{
                .ByteWidth = byteSize(opts.kind, count),
                // DYNAMIC with WRITE_DISCARD: these are rewritten whole every frame, which is
                // exactly the case the discard path is for. Writing a DEFAULT buffer with
                // UpdateSubresource stalls on the previous frame's use of it.
                .Usage = api.Usage.dynamic,
                .BindFlags = opts.kind.bindFlag(),
                .CPUAccessFlags = api.CpuAccess.write,
                .MiscFlags = if (opts.kind == .structured) misc_structured else 0,
                // The stride is what makes a structured buffer structured; zero here is
                // rejected at creation rather than misread later, which is the good outcome.
                .StructureByteStride = if (opts.kind == .structured) @sizeOf(T) else 0,
            };
            var initial: com.D3D11_SUBRESOURCE_DATA = undefined;
            var initial_ptr: ?*com.D3D11_SUBRESOURCE_DATA = null;
            if (data) |d| {
                initial = .{ .pSysMem = @constCast(@ptrCast(d)), .SysMemPitch = 0, .SysMemSlicePitch = 0 };
                initial_ptr = &initial;
            }
            var raw: ?*anyopaque = null;
            try api.check("CreateBuffer", opts.device.vt().CreateBuffer(
                opts.device.ptr,
                &desc,
                @ptrCast(initial_ptr),
                &raw,
            ));
            return api.Buffer.from(raw) orelse api.Error.CallFailed;
        }

        /// The view a structured buffer is read through, or null for the other kinds.
        fn makeView(opts: Options, buffer: api.Buffer, count: usize) api.Error!?api.ShaderResourceView {
            if (opts.kind != .structured) return null;
            _ = count;
            // A null descriptor, deliberately.
            //
            // A null desc creates a view over the whole resource, which for a structured
            // buffer is exactly what is wanted: the format is UNKNOWN and the element count
            // comes from the buffer's own size and stride, so there is nothing to state twice
            // and nothing to get out of step when the buffer grows.
            //
            // It is also the only correct option here. D3D11_SHADER_RESOURCE_VIEW_DESC is not
            // in the generated bindings: its payload is an anonymous union, and Win32 metadata
            // names all 568 of those `_Anonymous_e__Union`, so a reference to one by name
            // cannot be resolved to a layout. The generator now refuses rather than guessing.
            // The earlier version of this function filled in that struct field by field, and
            // it compiled -- against whichever of the four view descriptors' unions happened
            // to be generated first.
            var raw: ?*anyopaque = null;
            try api.check("CreateShaderResourceView", opts.device.vt().CreateShaderResourceView(
                opts.device.ptr,
                buffer.ptr,
                null,
                &raw,
            ));
            return api.ShaderResourceView.from(raw) orelse api.Error.CallFailed;
        }

        pub fn init(opts: Options, len: usize) !Self {
            const resource = try create(opts, len, null);
            errdefer resource.release();
            return .{
                .buffer = .{ .resource = resource, .srv = try makeView(opts, resource, len) },
                .opts = opts,
                .len = len,
            };
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            const resource = try create(opts, data.len, @ptrCast(data.ptr));
            errdefer resource.release();
            return .{
                .buffer = .{ .resource = resource, .srv = try makeView(opts, resource, data.len) },
                .opts = opts,
                .len = data.len,
            };
        }

        pub fn deinit(self: Self) void {
            self.buffer.release();
        }

        /// Map the whole buffer for a discard write.
        fn map(self: Self) api.Error![*]u8 {
            var mapped: com.D3D11_MAPPED_SUBRESOURCE = undefined;
            try api.check("Map", self.opts.context.vt().Map(
                self.opts.context.ptr,
                self.buffer.resource.ptr,
                0,
                api.Map.write_discard,
                0,
                &mapped,
            ));
            return @ptrCast(mapped.pData orelse return api.Error.CallFailed);
        }

        fn unmap(self: Self) void {
            self.opts.context.vt().Unmap(self.opts.context.ptr, self.buffer.resource.ptr, 0);
        }

        /// Grow to hold at least `count` elements, discarding the contents.
        ///
        /// A D3D11 buffer cannot be resized, so this replaces it. The old one is released only
        /// after the new one exists, so a failed growth leaves a usable buffer rather than
        /// none -- the renderer's next frame then draws the previous contents instead of
        /// crashing, which is the better of the two failures.
        fn grow(self: *Self, count: usize) api.Error!void {
            const bigger = try create(self.opts, count * 2, null);
            errdefer bigger.release();
            // The view describes an element count, so it is rebuilt with the buffer. Keeping
            // the old one would leave the shader reading the previous, smaller extent.
            const view = try makeView(self.opts, bigger, count * 2);
            self.buffer.release();
            self.buffer = .{ .resource = bigger, .srv = view };
            self.len = count * 2;
        }

        pub fn sync(self: *Self, data: []const T) !void {
            if (data.len == 0) return;
            if (data.len > self.len) try self.grow(data.len);
            const dst = try self.map();
            defer self.unmap();
            @memcpy(dst[0 .. data.len * @sizeOf(T)], std.mem.sliceAsBytes(data));
        }

        /// As `sync`, from several lists, returning how many elements were written.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total: usize = 0;
            for (lists) |l| total += l.items.len;
            if (total == 0) return 0;
            if (total > self.len) try self.grow(total);

            const dst = try self.map();
            defer self.unmap();
            var off: usize = 0;
            for (lists) |l| {
                if (l.items.len == 0) continue;
                const bytes = std.mem.sliceAsBytes(l.items);
                @memcpy(dst[off .. off + bytes.len], bytes);
                off += bytes.len;
            }
            return total;
        }
    };
}
