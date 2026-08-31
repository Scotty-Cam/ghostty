//! The HLSL each pipeline is compiled from, embedded so the backend carries its own shaders
//! rather than depending on files beside the executable.
//!
//! Its own file rather than a member of the index, so `shaders.zig` can name it without
//! importing the index that imports `shaders.zig`.
//!
//! Assembled at comptime rather than left to `#include`. D3DCompile resolves includes through
//! an include handler, and passing null -- which is what a backend with no filesystem to search
//! does -- makes every `#include` a compile error. Implementing ID3DInclude instead means
//! hand-writing a COM interface, which is what ADR-002 forbids, and for no gain: the include
//! graph is two files deep and known at compile time.
//!
//! The files keep their `#include` lines so fxc can still compile them standalone in the
//! verification lane; the directive is stripped here instead.

const std = @import("std");

const common_src = @embedFile("../shaders/hlsl/common.hlsl");
const full_screen_src = @embedFile("../shaders/hlsl/full_screen.hlsl");

/// Strip `#include` lines. They are satisfied by concatenation instead.
fn body(comptime src: []const u8) []const u8 {
    comptime {
        // The shader sources run to a few hundred lines each and this walks them line by
        // line, which is well past the default thousand-branch comptime budget.
        @setEvalBranchQuota(200_000);
        var out: []const u8 = "";
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            const t = std.mem.trimLeft(u8, line, " \t");
            if (std.mem.startsWith(u8, t, "#include")) continue;
            out = out ++ line ++ "\n";
        }
        return out;
    }
}

fn assemble(comptime src: []const u8, comptime with_full_screen: bool) [:0]const u8 {
    comptime {
        const head = body(common_src) ++
            (if (with_full_screen) body(full_screen_src) else "");
        return head ++ body(src) ++ "\x00";
    }
}

pub const bg_color: [:0]const u8 = assemble(@embedFile("../shaders/hlsl/bg_color.hlsl"), true);
/// Draws a render target into the back buffer. Not one of the renderer's pipelines -- it
/// belongs to `present`, which is why it needs neither the globals nor the full-screen helper.
pub const blit: [:0]const u8 = @embedFile("../shaders/hlsl/blit.hlsl") ++ "\x00";
pub const cell_bg: [:0]const u8 = assemble(@embedFile("../shaders/hlsl/cell_bg.hlsl"), true);
pub const cell_text: [:0]const u8 = assemble(@embedFile("../shaders/hlsl/cell_text.hlsl"), false);
pub const image: [:0]const u8 = assemble(@embedFile("../shaders/hlsl/image.hlsl"), false);
pub const bg_image: [:0]const u8 = assemble(@embedFile("../shaders/hlsl/bg_image.hlsl"), false);
