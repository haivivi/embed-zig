//! Simulated HAL Drivers for raysim
//!
//! Provides simulated hardware drivers for desktop testing.
//! These drivers communicate with the raylib UI through SimState.

const std = @import("std");
const sim_state_mod = @import("../raylib/sim_state.zig");

// Re-export from sim_state
pub const SimState = sim_state_mod.SimState;
pub const Color = sim_state_mod.Color;
pub const ButtonEvent = sim_state_mod.ButtonEvent;
pub const MAX_LEDS = sim_state_mod.MAX_LEDS;

/// Global simulation state
pub const state = &sim_state_mod.state;

// ============================================================================
// RTC Driver
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        state.start_time = std.time.milliTimestamp();
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        const now = std.time.milliTimestamp();
        return @intCast(now - state.start_time);
    }

    pub fn read(_: *Self) ?i64 {
        return std.time.milliTimestamp();
    }
};

// ============================================================================
// Button Driver
// ============================================================================

pub const ButtonDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        state.addLog("Simulator: Button ready");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    /// Returns true if button is pressed (consumes the press latch)
    /// Uses sticky latch to ensure fast clicks are not missed
    pub fn isPressed(_: *const Self) bool {
        const result = state.pollButtonState();
        if (result) {
            sim_state_mod.debugLog("[DRIVER] isPressed -> true\n", .{});
        }
        return result;
    }
};

// ============================================================================
// LED Strip Driver (generic - use board-specific version for HAL compatibility)
// ============================================================================

/// Generic LED driver that accepts any color type with r, g, b fields.
/// Note: For HAL compatibility, define a board-specific driver using hal.Color.
pub const LedDriver = struct {
    const Self = @This();

    count: u32,

    pub fn init() !Self {
        state.addLog("Simulator: LED initialized");
        return .{ .count = state.led_count };
    }

    pub fn deinit(_: *Self) void {}

    /// Set pixel color (generic version - accepts any type with r, g, b)
    pub fn setPixelGeneric(_: *Self, index: u32, color: anytype) void {
        if (index < MAX_LEDS) {
            state.led_colors[index] = Color.rgb(color.r, color.g, color.b);
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
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
            state.addLog(msg);
            std.debug.print("[INFO] {s}\n", .{msg});
        }

        pub fn err(comptime fmt: []const u8, args: anytype) void {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
            state.addLog(msg);
            std.debug.print("[ERROR] {s}\n", .{msg});
        }

        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
            state.addLog(msg);
            std.debug.print("[WARN] {s}\n", .{msg});
        }

        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            _ = fmt;
            _ = args;
        }
    };

    pub const time = struct {
        /// Sleep with early exit support
        pub fn sleepMs(ms: u32) void {
            var remaining = ms;
            while (remaining > 0 and state.isRunning()) {
                const chunk = @min(remaining, 50);
                std.Thread.sleep(@as(u64, chunk) * std.time.ns_per_ms);
                remaining -= chunk;
            }
        }

        pub fn getTimeMs() u64 {
            const now = std.time.milliTimestamp();
            return @intCast(now - state.start_time);
        }
    };

    /// Check if simulator is still running
    pub fn isRunning() bool {
        return state.isRunning();
    }
};

// ============================================================================
// Note: HAL Specs should be defined in board files using hal.Meta
// to ensure type compatibility with HAL's spec verifier.
// ============================================================================
