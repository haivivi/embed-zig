//! H106 Board — 240x240 screen + 7 ADC buttons + power button + 9 LED strip
//!
//! - 240x240 SPI LCD (RGB565)
//! - 7 ADC buttons: vol+, vol-, left, right, back, confirm, rec
//! - 1 power button (independent GPIO)
//! - 9 LED strip (WS2812, diamond layout)
//! - AEC audio system (speaker + mic) — TODO

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
// Button IDs
// ============================================================================

/// 7 ADC buttons on a resistor ladder
pub const ButtonId = enum(u8) {
    vol_up = 0,
    vol_down = 1,
    left = 2,
    right = 3,
    back = 4,
    confirm = 5,
    rec = 6,
};

// ============================================================================
// ADC ranges for button group
//
// Simulated ADC values (0-4095). Each button maps to a range.
// JS sets adc_raw to the center of the range when a button is pressed.
// ============================================================================

pub const adc_ranges = &[_]hal.ButtonGroupRange{
    .{ .id = 0, .min = 100, .max = 300 }, // vol_up: ~200
    .{ .id = 1, .min = 400, .max = 600 }, // vol_down: ~500
    .{ .id = 2, .min = 700, .max = 900 }, // left: ~800
    .{ .id = 3, .min = 1000, .max = 1200 }, // right: ~1100
    .{ .id = 4, .min = 1300, .max = 1500 }, // back: ~1400
    .{ .id = 5, .min = 1600, .max = 1800 }, // confirm: ~1700
    .{ .id = 6, .min = 1900, .max = 2100 }, // rec: ~2000
};

/// ADC center values for each button (used by JS to set adc_raw)
pub const adc_values = [_]u16{ 200, 500, 800, 1100, 1400, 1700, 2000 };

// ============================================================================
// LED Driver (adapts hal.Color to websim.Color)
// ============================================================================

pub const led_count: u32 = 9;

pub const LedDriver = struct {
    const Self = @This();
    count: u32,

    pub fn init() !Self {
        state.state.led_count = led_count;
        state.state.addLog("WebSim: LED strip (9) initialized");
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

pub const adc_button_spec = struct {
    pub const Driver = drivers.AdcButtonDriver;
    pub const ranges = adc_ranges;
    pub const ref_value: u16 = 4095;
    pub const ref_tolerance: u16 = 200;
    pub const meta = .{ .id = "buttons.adc" };
};

pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.status" };
};

/// Display dimensions for H106
pub const display_width: u16 = 240;
pub const display_height: u16 = 240;

/// SPI LCD driver: SpiLcd(SimSpi, SimDcPin) — goes through simulated SPI bus.
/// Use directly with ui.init(Display, &display).
pub const Display = display.SpiLcd(spi_sim.SimSpi, spi_sim.SimDcPin, .{
    .width = display_width,
    .height = display_height,
    .color_format = .rgb565,
    .render_mode = .partial,
    .buf_lines = 20,
});

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

pub const log = drivers.sal.log;
pub const time = drivers.sal.time;
pub const isRunning = drivers.sal.isRunning;
