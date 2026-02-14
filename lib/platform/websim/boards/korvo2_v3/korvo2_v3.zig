//! Korvo-2 V3 Board — 6 ADC buttons + 1 TCA9554 LED
//!
//! Mimics the real ESP32-S3-Korvo-2 V3 layout:
//! - 6 ADC buttons: vol_up, vol_down, set, play, mute, rec
//! - 1 TCA9554-controlled LED
//! - Speaker + Mic (sim)
//! - WiFi + Net + BLE (sim)

const hal = @import("hal");
const drivers = @import("../../impl/drivers.zig");
const wifi_mod = @import("../../impl/wifi.zig");
const net_mod = @import("../../impl/net.zig");
const speaker_mod = @import("../../impl/speaker.zig");
const mic_mod = @import("../../impl/mic.zig");
const ble_mod = @import("../../impl/ble.zig");
const audio_system_mod = @import("../../impl/audio_system.zig");
const state = @import("../../impl/state.zig");

// ============================================================================
// Button IDs — matches real Korvo-2 V3 ADC button layout
// ============================================================================

pub const ButtonId = enum(u8) {
    vol_up = 0,
    vol_down = 1,
    set = 2,
    play = 3,
    mute = 4,
    rec = 5,
};

// ============================================================================
// ADC ranges for button group
//
// Simulated ADC values (0-4095). Each button maps to a range.
// JS sets adc_raw to the center of the range when a button is pressed.
// ============================================================================

pub const adc_ranges = &[_]hal.ButtonGroupRange{
    .{ .id = 0, .min = 250, .max = 600 }, // vol_up: ~425
    .{ .id = 1, .min = 750, .max = 1100 }, // vol_down: ~925
    .{ .id = 2, .min = 1110, .max = 1500 }, // set: ~1300
    .{ .id = 3, .min = 1510, .max = 2100 }, // play: ~1800
    .{ .id = 4, .min = 2110, .max = 2550 }, // mute: ~2330
    .{ .id = 5, .min = 2650, .max = 3100 }, // rec: ~2875
};

/// ADC center values for each button (used by JS to set adc_raw)
pub const adc_values = [_]u16{ 425, 925, 1300, 1800, 2330, 2875 };

// ============================================================================
// LED Driver (1 TCA9554 LED — real Korvo-2 V3 hardware)
// ============================================================================

pub const led_count: u32 = 1;

pub const LedDriver = struct {
    const Self = @This();
    count: u32,

    pub fn init() !Self {
        state.state.led_count = led_count;
        state.state.addLog("WebSim: Korvo2 LED (TCA9554) initialized");
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

pub const adc_button_spec = struct {
    pub const Driver = drivers.AdcButtonDriver;
    pub const ranges = adc_ranges;
    pub const ref_value: u16 = 4095;
    pub const ref_tolerance: u16 = 500;
    pub const meta = .{ .id = "buttons.adc" };
};

pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.strip" };
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

// AudioSystem + PA switch (for aec_test)
pub const AudioSystem = audio_system_mod.AudioSystem;
pub const PaSwitchDriver = audio_system_mod.PaSwitchDriver;

// Hardware info (for aec_test compatibility)
pub const name = "WebSim Korvo-2 V3";
pub const sample_rate: u32 = 16000;

// ============================================================================
// Board Config JSON (embedded in WASM, read by JS to render UI)
// ============================================================================

pub const board_config_json =
    \\{"name":"ESP32-S3 Korvo-2 V3","chip":"ESP32-S3",
    \\"leds":{"count":1,"type":"tca9554","layout":"single"},
    \\"buttons":{"adc":[
    \\{"name":"VOL+","value":425},{"name":"VOL-","value":925},
    \\{"name":"SET","value":1300},{"name":"PLAY","value":1800},
    \\{"name":"MUTE","value":2330},{"name":"REC","value":2875}
    \\],"boot":true,"power":false},
    \\"display":null,
    \\"audio":{"speaker":true,"mic":true,"aec":true,"sample_rate":16000},
    \\"wifi":true,"ble":true}
;

pub const log = drivers.sal.log;
pub const time = drivers.sal.time;
pub const isRunning = drivers.sal.isRunning;
