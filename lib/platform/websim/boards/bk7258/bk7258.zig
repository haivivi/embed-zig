//! BK7258 Board — 800x480 RGB LCD + buttons + WiFi + BLE
//!
//! - 800x480 RGB LCD (RGB565)
//! - Power button
//! - BOOT button
//! - WiFi + BLE
//! - KVS storage
//! - Speaker + Mic

const hal = @import("hal");
const display = @import("display");
const drivers = @import("../../impl/drivers.zig");
const spi_sim = @import("../../impl/spi.zig");
const wifi_mod = @import("../../impl/wifi.zig");
const net_mod = @import("../../impl/net.zig");
const speaker_mod = @import("../../impl/speaker.zig");
const mic_mod = @import("../../impl/mic.zig");
const ble_mod = @import("../../impl/ble.zig");
const state = @import("../../impl/state.zig");

// ============================================================================
// Display
// ============================================================================

/// Display dimensions for BK7258
pub const display_width: u16 = 800;
pub const display_height: u16 = 480;

/// SPI LCD driver: SpiLcd(SimSpi, SimDcPin) with 800x480 resolution.
pub const Display = display.SpiLcd(spi_sim.SimSpi, spi_sim.SimDcPin, .{
    .width = display_width,
    .height = display_height,
    .color_format = .rgb565,
    .render_mode = .partial,
    .buf_lines = 20,
});

// ============================================================================
// LED Driver (single status LED)
// ============================================================================

pub const led_count: u32 = 1;

pub const LedDriver = struct {
    const Self = @This();
    count: u32,

    pub fn init() !Self {
        state.state.led_count = led_count;
        // Set display dimensions for BK7258 (800x480)
        state.state.display_width = display_width;
        state.state.display_height = display_height;
        state.state.addLog("WebSim: BK7258 initialized (800x480 display)");
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

pub const power_button_spec = struct {
    pub const Driver = drivers.PowerButtonDriver;
    pub const meta = .{ .id = "button.power" };
};

pub const button_spec = struct {
    pub const Driver = drivers.ButtonDriver;
    pub const meta = .{ .id = "button.boot" };
};

pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.status" };
};

pub const wifi_spec = struct {
    pub const Driver = wifi_mod.WifiDriver;
    pub const meta = .{ .id = "wifi.sim" };
};

pub const net_spec = struct {
    pub const Driver = net_mod.NetDriver;
    pub const meta = .{ .id = "net.sim" };
};

pub const speaker_spec = struct {
    pub const Driver = speaker_mod.SpeakerDriver;
    pub const meta = .{ .id = "speaker.sim" };
    pub const config = hal.mono_speaker.Config{
        .sample_rate = 16000,
        .bits_per_sample = 16,
    };
};

pub const mic_spec = struct {
    pub const Driver = mic_mod.MicDriver;
    pub const meta = .{ .id = "mic.sim" };
    pub const config = hal.mic.Config{
        .sample_rate = 16000,
        .channels = 1,
        .bits_per_sample = 16,
    };
};

pub const ble_spec = struct {
    pub const Driver = ble_mod.BleDriver;
    pub const meta = .{ .id = "ble.sim" };
};

// ============================================================================
// Board Config JSON (embedded in WASM, read by JS to render UI)
// ============================================================================

pub const board_config_json =
    \\{"name":"BK7258","chip":"BK7258",
    \\"leds":{"count":1,"type":"gpio","layout":"single"},
    \\"buttons":{"adc":[],"boot":true,"power":true},
    \\"display":{"width":800,"height":480},
    \\"audio":{"speaker":true,"mic":true,"aec":false,"sample_rate":16000},
    \\"wifi":true,"ble":true}
;

pub const log = drivers.sal.log;
pub const time = drivers.sal.time;
pub const isRunning = drivers.sal.isRunning;
