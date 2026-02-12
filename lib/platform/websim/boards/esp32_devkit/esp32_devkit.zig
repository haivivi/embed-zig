//! ESP32-S3 DevKit Board — 1 BOOT button + 1 RGB LED
//!
//! Mimics the real ESP32-S3-DevKitC-1 layout.

const hal = @import("hal");
const drivers = @import("../../impl/drivers.zig");
const state = @import("../../impl/state.zig");

pub const led_count: u32 = 1;

pub const LedDriver = struct {
    const Self = @This();
    count: u32,

    pub fn init() !Self {
        state.state.led_count = led_count;
        state.state.addLog("WebSim: RGB LED initialized");
        return .{ .count = led_count };
    }

    pub fn deinit(_: *Self) void {}

    pub fn setPixel(_: *Self, index: u32, color: hal.Color) void {
        if (index < state.MAX_LEDS) {
            state.state.led_colors[index] = .{ .r = color.r, .g = color.g, .b = color.b };
        }
    }

    pub fn getPixelCount(self: *Self) u32 {
        return self.count;
    }

    pub fn refresh(_: *Self) void {}
};

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = drivers.RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const button_spec = struct {
    pub const Driver = drivers.ButtonDriver;
    pub const meta = .{ .id = "button.boot" };
};

pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.rgb" };
};

pub const log = drivers.sal.log;
pub const time = drivers.sal.time;
pub const isRunning = drivers.sal.isRunning;
