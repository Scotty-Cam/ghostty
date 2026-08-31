//! The pipelines the renderer draws with, and the data types they read.
//!
//! The vertex and uniform types are the same shapes the other backends use -- the generic
//! renderer fills them in and does not know which backend it is talking to -- so they are
//! mirrored here rather than reinvented.

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("../../math.zig");
const api = @import("api.zig");
const Pipeline = @import("Pipeline.zig");
const src = @import("sources.zig");

const log = std.log.scoped(.d3d11);

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{ .source = src.bg_color, .blending_enabled = false } },
        .{ "cell_bg", .{ .source = src.cell_bg } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .source = src.cell_text,
            .step_fn = .per_instance,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .source = src.image,
            .step_fn = .per_instance,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .source = src.bg_image,
            .step_fn = .per_instance,
        } },
    };

const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    source: [:0]const u8,
    step_fn: Pipeline.Options.StepFunction = .per_vertex,
    blending_enabled: bool = true,

    fn initPipeline(self: PipelineDescription, name: [:0]const u8, device: api.Device) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .source = self.source,
            .name = name,
            .step_fn = self.step_fn,
            .blending_enabled = self.blending_enabled,
            .device = device,
        });
    }
};

/// The pipelines, named.
///
/// Written out rather than built with `@Type` over the description list, which is what the
/// other backends do. Two reasons: the reflection buys nothing over five field names, and
/// `@Type` does not exist in the Zig that upstream's main branch now requires -- so the
/// generated version replayed cleanly onto upstream and then failed to compile, which is a
/// maintenance cost this backend would have paid at every sync for no benefit.
const PipelineCollection = struct {
    bg_color: Pipeline,
    cell_bg: Pipeline,
    cell_text: Pipeline,
    image: Pipeline,
    bg_image: Pipeline,
};

pub const Shaders = struct {
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline,
    defunct: bool = false,

    pub fn init(
        alloc: Allocator,
        device: api.Device,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        var pipelines: PipelineCollection = undefined;
        var initialized: usize = 0;
        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized) @field(pipelines, pipeline[0]).deinit();
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(pipeline[0], device);
            initialized += 1;
        }

        const post_pipelines: []const Pipeline = initPostPipelines(
            alloc,
            device,
            post_shaders,
        ) catch |err| err: {
            // A broken custom shader must not stop the terminal starting, which is the
            // behaviour every other backend has.
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };

        return .{ .pipelines = pipelines, .post_pipelines = post_pipelines };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(self.post_pipelines);
        }
    }
};

fn initPostPipelines(
    alloc: Allocator,
    device: api.Device,
    sources: []const [:0]const u8,
) ![]const Pipeline {
    if (sources.len == 0) return &.{};
    const pipelines = try alloc.alloc(Pipeline, sources.len);
    errdefer alloc.free(pipelines);
    var i: usize = 0;
    errdefer for (pipelines[0..i]) |p| p.deinit();
    for (sources) |source| {
        pipelines[i] = try .init(null, .{
            .source = source,
            .name = "custom",
            .blending_enabled = false,
            .device = device,
        });
        i += 1;
    }
    return pipelines;
}

/// The uniform block, matching the `Globals` constant buffer in common.hlsl.
pub const Uniforms = extern struct {
    projection_matrix: math.Mat align(16),
    screen_size: [2]f32 align(8),
    cell_size: [2]f32 align(8),
    grid_size: [2]u16 align(4),
    grid_padding: [4]f32 align(16),
    padding_extend: PaddingExtend align(4),
    min_contrast: f32 align(4),
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),
    bg_color: [4]u8 align(4),
    bools: Bools align(4),

    pub const Bools = packed struct(u32) {
        cursor_wide: bool,
        use_display_p3: bool,
        use_linear_blending: bool,
        use_linear_correction: bool = false,
        _padding: u28 = 0,
    };

    pub const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };

    // The offsets HLSL will read these fields at.
    //
    // A constant buffer is not packed the way a C struct is: a vector may not straddle a
    // 16-byte boundary, and one that would is pushed to the next one. Here that affects
    // `grid_padding`, a float4 which follows a uint at offset 84 and is therefore placed at
    // 96 rather than 88.
    //
    // The Zig alignments happen to produce the same layout, which is exactly why this is
    // asserted rather than trusted: nothing about the declaration says the two rule sets
    // agree, and if a field is ever added above `grid_padding` they stop agreeing silently.
    // Every uniform would then be read from the wrong offset, and the picture would still
    // look like a terminal.
    comptime {
        const expect = .{
            .{ "projection_matrix", 0 },
            .{ "screen_size", 64 },
            .{ "cell_size", 72 },
            .{ "grid_size", 80 },
            .{ "grid_padding", 96 },
            .{ "padding_extend", 112 },
            .{ "min_contrast", 116 },
            .{ "cursor_pos", 120 },
            .{ "cursor_color", 124 },
            .{ "bg_color", 128 },
            .{ "bools", 132 },
        };
        for (expect) |e| {
            if (@offsetOf(Uniforms, e[0]) != e[1]) @compileError(std.fmt.comptimePrint(
                "Uniforms.{s} is at offset {d}, but the HLSL constant buffer reads it at {d}",
                .{ e[0], @offsetOf(Uniforms, e[0]), e[1] },
            ));
        }
    }
};

/// One instance of the cell text shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };
};

/// One cell's background colour.
pub const CellBg = [4]u8;

/// One image placement.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// The background image.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0, tc = 1, tr = 2,
            ml = 3, mc = 4, mr = 5,
            bl = 6, bc = 7, br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};
