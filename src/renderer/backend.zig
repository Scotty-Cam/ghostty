const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Possible implementations, used for build options.
pub const Backend = enum {
    opengl,
    metal,
    webgl,
    /// Direct3D 11, for Windows. Selected by ADR-002: the inherited D3D12 backend has no
    /// minimal working closure against this pin.
    d3d11,

    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .webgl,
            };
        }

        if (target.os.tag.isDarwin()) return .metal;
        // Not defaulted on Windows yet. The backend exists and draws, but the embedded
        // runtime's surface lifecycle is not wired to it, so defaulting would change what an
        // ordinary Windows build produces before anything can drive it. Selected explicitly
        // with -Drenderer=d3d11 until then.
        return .opengl;
    }
};
