//! WASM Export Helpers for WebSim
//!
//! Provides the standard WASM export functions that the JS shell expects.
//! Uses typed accessor exports instead of raw memory offsets — this ensures
//! correctness regardless of Zig's struct layout decisions.
//!
//! ## Usage (in app's wasm_main.zig)
//!
//! ```zig
//! const websim = @import("websim");
//!
//! comptime {
//!     websim.wasm.exportAll(@This());
//! }
//!
//! pub fn init() void { ... }
//! pub fn step() void { ... }
//! ```

const std = @import("std");
const state_mod = @import("../impl/state.zig");

const shared = &state_mod.state;

// ============================================================================
// Input exports (JS → WASM)
// ============================================================================

/// Set button pressed state (called by JS on mousedown)
export fn buttonPress() void {
    shared.setButtonPressed(true);
}

/// Set button released state (called by JS on mouseup)
export fn buttonRelease() void {
    shared.setButtonPressed(false);
}

/// Update time (called by JS each frame with performance.now())
export fn setTime(ms: u32) void {
    shared.time_ms = @as(u64, ms);
}

// ============================================================================
// State accessor exports (WASM → JS reads)
// ============================================================================

// ---- LEDs ----

export fn getLedCount() u32 {
    return shared.led_count;
}

/// Get LED color as packed u32: 0x00RRGGBB
export fn getLedColor(index: u32) u32 {
    if (index >= state_mod.MAX_LEDS) return 0;
    const c = shared.led_colors[index];
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.b);
}

// ---- ADC button group ----

/// Set simulated ADC value (called by JS when a virtual button is pressed)
export fn setAdcValue(raw: u32) void {
    shared.adc_raw = @intCast(@min(raw, 4095));
}

// ---- Power button ----

export fn powerPress() void {
    shared.setPowerPressed(true);
}

export fn powerRelease() void {
    shared.setPowerPressed(false);
}

// ---- Display framebuffer ----

/// Get pointer to display framebuffer (240x240 RGB565)
export fn getDisplayFbPtr() [*]const u8 {
    return &shared.display_fb;
}

export fn getDisplayFbSize() u32 {
    return state_mod.DISPLAY_FB_SIZE;
}

export fn getDisplayWidth() u32 {
    return state_mod.DISPLAY_WIDTH;
}

export fn getDisplayHeight() u32 {
    return state_mod.DISPLAY_HEIGHT;
}

export fn getDisplayDirty() u32 {
    return if (shared.display_dirty) 1 else 0;
}

export fn clearDisplayDirty() void {
    shared.display_dirty = false;
}

// ---- Log ----

export fn getLogCount() u32 {
    return shared.log_count;
}

export fn getLogDirty() u32 {
    return if (shared.log_dirty) 1 else 0;
}

export fn clearLogDirty() void {
    shared.log_dirty = false;
}

export fn getLogLinePtr(idx: u32) [*]const u8 {
    const total = @min(shared.log_count, state_mod.LOG_LINES_MAX);
    if (idx >= total) return @ptrCast(&shared.log_lines[0]);
    const actual_idx = if (shared.log_count < state_mod.LOG_LINES_MAX)
        idx
    else
        (shared.log_next + idx) % state_mod.LOG_LINES_MAX;
    return &shared.log_lines[actual_idx];
}

export fn getLogLineLen(idx: u32) u32 {
    const total = @min(shared.log_count, state_mod.LOG_LINES_MAX);
    if (idx >= total) return 0;
    const actual_idx = if (shared.log_count < state_mod.LOG_LINES_MAX)
        idx
    else
        (shared.log_next + idx) % state_mod.LOG_LINES_MAX;
    return @as(u32, shared.log_lens[actual_idx]);
}

// ============================================================================
// App init/step generation
// ============================================================================

/// Generate standard WASM exports for an app module.
///
/// The app module must provide:
/// - `fn init() void`
/// - `fn step() void`
///
/// This creates the `init` and `step` exports that the JS shell calls.
pub fn exportAll(comptime App: type) void {
    // Force all accessor exports to be included in the WASM binary
    _ = &buttonPress;
    _ = &buttonRelease;
    _ = &powerPress;
    _ = &powerRelease;
    _ = &setTime;
    _ = &setAdcValue;
    _ = &getLedCount;
    _ = &getLedColor;
    _ = &getDisplayFbPtr;
    _ = &getDisplayFbSize;
    _ = &getDisplayWidth;
    _ = &getDisplayHeight;
    _ = &getDisplayDirty;
    _ = &clearDisplayDirty;
    _ = &getLogCount;
    _ = &getLogDirty;
    _ = &clearLogDirty;
    _ = &getLogLinePtr;
    _ = &getLogLineLen;

    // Create app-specific exports
    const S = struct {
        fn wasmInit() callconv(.c) void {
            shared.start_time_ms = shared.time_ms;
            if (@hasDecl(App, "init")) {
                App.init();
            }
        }

        fn wasmStep() callconv(.c) void {
            if (@hasDecl(App, "step")) {
                App.step();
            }
        }
    };
    @export(&S.wasmInit, .{ .name = "init" });
    @export(&S.wasmStep, .{ .name = "step" });

    // WASI libc requires main(argc, argv). Provide a no-op — JS calls init/step directly.
    const M = struct {
        fn wasmMain(_: c_int, _: [*]const [*]const u8) callconv(.c) c_int {
            return 0;
        }
    };
    @export(&M.wasmMain, .{ .name = "main" });
}
