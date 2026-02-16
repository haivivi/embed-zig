//! WebSim HAL Drivers
//!
//! Simulated hardware drivers for WASM/browser.
//! Communicates with JS through SharedState in linear memory.

const std = @import("std");
const state_mod = @import("state.zig");

pub const SharedState = state_mod.SharedState;
pub const Color = state_mod.Color;
pub const MAX_LEDS = state_mod.MAX_LEDS;
pub const DISPLAY_WIDTH = state_mod.DISPLAY_WIDTH;
pub const DISPLAY_HEIGHT = state_mod.DISPLAY_HEIGHT;

/// Global shared state
pub const shared = &state_mod.state;

const builtin = @import("builtin");
const is_wasm = builtin.target.cpu.arch == .wasm32;

// ============================================================================
// Platform-specific imports
// ============================================================================

const env = if (is_wasm) struct {
    extern "env" fn consoleLog(ptr: [*]const u8, len: u32) void;
} else struct {
    fn consoleLog(ptr: [*]const u8, len: u32) void {
        std.debug.print("{s}\n", .{ptr[0..len]});
    }
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

    /// Returns true while button is physically held down.
    /// HAL button module handles debouncing and edge detection.
    pub fn isPressed(_: *const Self) bool {
        return shared.button_pressed;
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
// Power Button Driver (single GPIO button)
// ============================================================================

pub const PowerButtonDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        shared.addLog("WebSim: Power button ready");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    /// Returns true while power button is physically held down.
    /// HAL button module handles debouncing and edge detection.
    pub fn isPressed(_: *const Self) bool {
        return shared.power_pressed;
    }
};

// ============================================================================
// ADC Button Group Driver
// ============================================================================

/// Simulated ADC reader for button group.
/// JS sets the ADC value based on which virtual button is pressed.
pub const AdcButtonDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        shared.addLog("WebSim: ADC buttons ready");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    /// Read simulated ADC value (0-4095).
    /// 4095 = no button pressed. JS sets specific values per button.
    pub fn readRaw(_: *Self) u16 {
        return shared.readAdc();
    }
};

// Display driver has moved to SPI-based architecture.
// See lib/platform/websim/impl/spi.zig (SimSpi + SimDcPin)
// and lib/pkg/display/src/spi_lcd.zig (SpiLcd generic driver).
// Board definitions create: display.SpiLcd(SimSpi, SimDcPin, config)

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
        /// Sleep for the given number of milliseconds.
        /// WASM: no-op (cooperative stepping). Native: real sleep.
        pub fn sleepMs(ms: u32) void {
            if (!is_wasm) {
                std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
            }
        }

        pub fn nowMs() u64 {
            return shared.uptime();
        }

        pub fn nowMs() u64 {
            return shared.uptime();
        }
    };

    /// Check if simulator is still running
    pub fn isRunning() bool {
        return shared.running;
    }
};
