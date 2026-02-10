//! WebSim HAL Drivers
//!
//! Simulated hardware drivers for WASM/browser.
//! Communicates with JS through SharedState in linear memory.

const std = @import("std");
const state_mod = @import("state.zig");

pub const SharedState = state_mod.SharedState;
pub const Color = state_mod.Color;
pub const MAX_LEDS = state_mod.MAX_LEDS;

/// Global shared state
pub const shared = &state_mod.state;

// ============================================================================
// WASM imports (provided by JS)
// ============================================================================

/// JS-provided functions via WASM import "env"
const env = struct {
    extern "env" fn consoleLog(ptr: [*]const u8, len: u32) void;
};

// ============================================================================
// RTC Driver
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        shared.start_time_ms = shared.time_ms;
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return shared.uptime();
    }

    /// Return current wall clock time in ms (or null if not available)
    pub fn nowMs(_: *Self) ?i64 {
        return @intCast(shared.time_ms);
    }
};

// ============================================================================
// Button Driver
// ============================================================================

pub const ButtonDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        shared.addLog("WebSim: Button ready");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    /// Returns true if button is pressed (consumes the press latch)
    pub fn isPressed(_: *const Self) bool {
        return shared.pollButtonState();
    }
};

// ============================================================================
// LED Strip Driver
// ============================================================================

pub const LedDriver = struct {
    const Self = @This();

    count: u32,

    pub fn init() !Self {
        shared.addLog("WebSim: LED initialized");
        return .{ .count = shared.led_count };
    }

    pub fn deinit(_: *Self) void {}

    /// Set pixel color (uses hal.Color compatible interface)
    pub fn setPixel(_: *Self, index: u32, color: anytype) void {
        if (index < MAX_LEDS) {
            shared.led_colors[index] = Color.rgb(color.r, color.g, color.b);
        }
    }

    pub fn getPixelCount(self: *Self) u32 {
        return self.count;
    }

    pub fn refresh(_: *Self) void {}
};

// ============================================================================
// SAL (System Abstraction Layer)
// ============================================================================

pub const sal = struct {
    pub const log = struct {
        pub fn info(comptime fmt: []const u8, args: anytype) void {
            writeLog("[INFO] ", fmt, args);
        }

        pub fn err(comptime fmt: []const u8, args: anytype) void {
            writeLog("[ERROR] ", fmt, args);
        }

        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            writeLog("[WARN] ", fmt, args);
        }

        pub fn debug(_: []const u8, _: anytype) void {}

        fn writeLog(prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
            var buf: [256]u8 = undefined;
            // Write prefix
            const plen = prefix.len;
            @memcpy(buf[0..plen], prefix);
            // Format message after prefix
            const msg = std.fmt.bufPrint(buf[plen..], fmt, args) catch return;
            const total = plen + msg.len;

            // Add to shared state log
            shared.addLog(buf[0..total]);

            // Also send to JS console
            env.consoleLog(&buf, @intCast(total));
        }
    };

    pub const time = struct {
        /// In WASM, sleep is a no-op — JS drives the frame loop.
        /// The step function is called each frame by requestAnimationFrame.
        pub fn sleepMs(_: u32) void {
            // No-op in WASM: cooperative stepping, not blocking
        }

        pub fn getTimeMs() u64 {
            return shared.uptime();
        }
    };

    /// Check if simulator is still running
    pub fn isRunning() bool {
        return shared.running;
    }
};
