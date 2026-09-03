// This is the main file for the C API. The C API is used to embed Ghostty
// within other applications. Depending on the build settings some APIs
// may not be available (i.e. embedding into macOS exposes various Metal
// support).
//
// This currently isn't supported as a general purpose embedding API.
// This is currently used only to embed ghostty within a macOS app. However,
// it could be expanded to be general purpose in the future.

const std = @import("std");
const assert = @import("quirks.zig").inlineAssert;
const posix = std.posix;
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const main = @import("main_ghostty.zig");
const state = &@import("global.zig").state;
const apprt = @import("apprt.zig");
const internal_os = @import("os/main.zig");

// Some comptime assertions that our C API depends on.
comptime {
    // We allow tests to reference this file because we unit test
    // some of the C API. At runtime though we should never get these
    // functions unless we are building libghostty.
    if (!builtin.is_test) {
        assert(apprt.runtime == apprt.embedded);
    }
}

/// Global options so we can log. This is identical to main.
pub const std_options = main.std_options;

comptime {
    // These structs need to be referenced so the `export` functions
    // are truly exported by the C API lib.

    // Our config API
    _ = @import("config.zig").CApi;

    // Any apprt-specific C API, mainly libghostty for apprt.embedded.
    if (@hasDecl(apprt.runtime, "CAPI")) _ = apprt.runtime.CAPI;

    // Our benchmark API. We probably want to gate this on a build
    // config in the future but for now we always just export it.
    _ = @import("benchmark/main.zig").CApi;
}

/// ghostty_info_s
const Info = extern struct {
    mode: BuildMode,
    version: [*]const u8,
    version_len: usize,

    const BuildMode = enum(c_int) {
        debug,
        release_safe,
        release_fast,
        release_small,
    };
};

/// ghostty_string_s
pub const String = extern struct {
    ptr: ?[*]const u8,
    len: usize,
    sentinel: bool,

    pub const empty: String = .{
        .ptr = null,
        .len = 0,
        .sentinel = false,
    };

    pub fn fromSlice(slice: anytype) String {
        return .{
            .ptr = slice.ptr,
            .len = slice.len,
            .sentinel = sentinel: {
                const info = @typeInfo(@TypeOf(slice));
                switch (info) {
                    .pointer => |p| {
                        if (p.size != .slice) @compileError("only slices supported");
                        if (p.child != u8) @compileError("only u8 slices supported");
                        const sentinel_ = p.sentinel();
                        if (sentinel_) |sentinel| if (sentinel != 0) @compileError("only 0 is supported for sentinels");
                        break :sentinel sentinel_ != null;
                    },
                    else => @compileError("only []const u8 and [:0]const u8"),
                }
            },
        };
    }

    pub fn deinit(self: *const String) void {
        const ptr = self.ptr orelse return;
        if (self.sentinel) {
            state.alloc.free(ptr[0..self.len :0]);
        } else {
            state.alloc.free(ptr[0..self.len]);
        }
    }
};

/// Initialize ghostty global state.
pub export fn ghostty_init(argc: usize, argv: [*][*:0]u8) c_int {
    assert(builtin.link_libc);

    std.os.argv = argv[0..argc];
    state.init() catch |err| {
        std.log.err("failed to initialize ghostty error={}", .{err});
        return 1;
    };

    return 0;
}

/// Runs an action if it is specified. If there is no action this returns
/// false. If there is an action then this doesn't return.
pub export fn ghostty_cli_try_action() void {
    const action = state.action orelse return;
    std.log.info("executing CLI action={}", .{action});
    posix.exit(action.run(state.alloc) catch |err| {
        std.log.err("CLI action failed error={}", .{err});
        posix.exit(1);
    });

    posix.exit(0);
}

/// Return metadata about Ghostty, such as version, build mode, etc.
/// The ABI this build of libghostty presents to Casprr, and what it was compiled with.
///
/// Casprr loads this library at run time and cannot rebuild it, so it needs two facts before
/// it calls anything: whether the interface is one it understands, and which optional
/// subsystems are actually present. Neither is answerable from the release string -- a
/// version number describes a source tree, not a build, and two builds of the same tag can
/// differ in renderer and app runtime.
///
/// Inferring either from symbol presence is the mistake this replaces. `ghostty_surface_new`
/// exists whatever renderer was compiled in, so a consumer that reads the export table
/// concludes the capability is there and calls into a subsystem that is not.
///
/// Bumped when the meaning of an existing entry point or capability bit changes. A purely
/// additive change -- a new bit, a new entry point -- does not bump it, because a consumer
/// that does not know about an addition is unharmed by it.
pub const CASPRR_CORE_ABI: u32 = 1;

/// Capability bits. The ABI version above defines what these mean; a consumer must compare
/// the version before reading them, or it is interpreting a bitfield by guesswork.
pub const CasprrCapability = struct {
    pub const renderer_opengl: u64 = 1 << 0;
    pub const renderer_metal: u64 = 1 << 1;
    pub const renderer_webgl: u64 = 1 << 2;
    pub const renderer_d3d11: u64 = 1 << 3;
    pub const apprt_embedded: u64 = 1 << 8;
    pub const apprt_gtk: u64 = 1 << 9;
    pub const apprt_none: u64 = 1 << 10;
    pub const platform_windows: u64 = 1 << 16;
    pub const platform_macos: u64 = 1 << 17;
    pub const font_freetype: u64 = 1 << 24;
    pub const font_coretext: u64 = 1 << 25;
    /// Set when the build carries the Windows platform arm of the embedded app runtime --
    /// Casprr's own patch. A core without it cannot host a surface on an HWND, and that is a
    /// different fact from the process running on Windows.
    pub const platform_arm_windows: u64 = 1 << 18;
};

pub export fn casprr_core_abi_version() callconv(.c) u32 {
    return CASPRR_CORE_ABI;
}

/// What this build actually compiled, read from the build configuration rather than from the
/// target or from what happens to be exported.
pub export fn casprr_core_capabilities() callconv(.c) u64 {
    var bits: u64 = 0;

    // Matched on the tag *name*, not by switch prong.
    //
    // These enums belong to upstream, and a carried patch has to compile at two points at once:
    // the pin it was written against, and whatever upstream looks like at the next sync. An
    // exhaustive switch breaks when upstream adds an arm; an `else` prong is a compile error at
    // the pin, where the switch is already exhaustive. Zig will not accept both, so neither
    // form can be carried -- which the first two versions of this patch discovered one replay
    // at a time.
    //
    // Comparing names compiles whatever arms exist. An arm we do not recognise contributes no
    // bit rather than being guessed at, and a consumer reads the capability as absent, which is
    // the truthful answer: we do not know what this build has.
    const rt = @tagName(build_config.app_runtime);
    if (std.mem.eql(u8, rt, "none")) {
        bits |= CasprrCapability.apprt_none | CasprrCapability.apprt_embedded;
    } else if (std.mem.eql(u8, rt, "gtk")) {
        bits |= CasprrCapability.apprt_gtk;
    }

    const rend = @tagName(build_config.renderer);
    if (std.mem.eql(u8, rend, "opengl")) {
        bits |= CasprrCapability.renderer_opengl;
    } else if (std.mem.eql(u8, rend, "metal")) {
        bits |= CasprrCapability.renderer_metal;
    } else if (std.mem.eql(u8, rend, "webgl")) {
        bits |= CasprrCapability.renderer_webgl;
    } else if (std.mem.eql(u8, rend, "d3d11")) {
        bits |= CasprrCapability.renderer_d3d11;
    }

    const fb = @tagName(build_config.font_backend);
    if (std.mem.startsWith(u8, fb, "coretext")) {
        bits |= CasprrCapability.font_coretext;
    } else if (std.mem.indexOf(u8, fb, "freetype") != null) {
        bits |= CasprrCapability.font_freetype;
    }

    if (builtin.target.os.tag == .windows) {
        bits |= CasprrCapability.platform_windows;
        // The arm exists in this source tree, so a build for Windows carries it. Reported
        // separately from the target because the two can diverge: a future core could target
        // Windows without the arm, and Casprr must be able to tell.
        if (@hasField(apprt.embedded.Platform.C, "windows")) {
            bits |= CasprrCapability.platform_arm_windows;
        }
    }
    if (builtin.target.os.tag.isDarwin()) bits |= CasprrCapability.platform_macos;
    return bits;
}

pub export fn ghostty_info() Info {
    return .{
        .mode = switch (builtin.mode) {
            .Debug => .debug,
            .ReleaseSafe => .release_safe,
            .ReleaseFast => .release_fast,
            .ReleaseSmall => .release_small,
        },
        .version = build_config.version_string.ptr,
        .version_len = build_config.version_string.len,
    };
}

/// Translate a string maintained by libghostty into the current
/// application language. This will return the same string (same pointer)
/// if no translation is found, so the pointer must be stable through
/// the function call.
///
/// This should only be used for singular strings maintained by Ghostty.
pub export fn ghostty_translate(msgid: [*:0]const u8) [*:0]const u8 {
    return internal_os.i18n._(msgid);
}

/// Free a string allocated by Ghostty.
pub export fn ghostty_string_free(str: String) void {
    str.deinit();
}

test "ghostty_string_s empty string" {
    const testing = std.testing;
    const empty_string = String.empty;
    defer empty_string.deinit();

    try testing.expect(empty_string.len == 0);
    try testing.expect(empty_string.sentinel == false);
}

test "ghostty_string_s c string" {
    const testing = std.testing;
    state.alloc = testing.allocator;

    const slice: [:0]const u8 = "hello";
    const allocated_slice = try testing.allocator.dupeZ(u8, slice);
    const c_null_string = String.fromSlice(allocated_slice);
    defer c_null_string.deinit();

    try testing.expect(allocated_slice[5] == 0);
    try testing.expect(@TypeOf(slice) == [:0]const u8);
    try testing.expect(@TypeOf(allocated_slice) == [:0]u8);
    try testing.expect(c_null_string.len == 5);
    try testing.expect(c_null_string.sentinel == true);
}

test "ghostty_string_s zig string" {
    const testing = std.testing;
    state.alloc = testing.allocator;

    const slice: []const u8 = "hello";
    const allocated_slice = try testing.allocator.dupe(u8, slice);
    const zig_string = String.fromSlice(allocated_slice);
    defer zig_string.deinit();

    try testing.expect(@TypeOf(slice) == []const u8);
    try testing.expect(@TypeOf(allocated_slice) == []u8);
    try testing.expect(zig_string.len == 5);
    try testing.expect(zig_string.sentinel == false);
}
