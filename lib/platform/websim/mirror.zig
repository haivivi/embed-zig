//! WebSim Board Mirror — comptime generates a WebSim board from a real board definition.
//!
//! Given any real board hw module (e.g., esp/korvo2_v3.zig), this produces a
//! WebSim-compatible hw module with the same specs but WebSim drivers.
//!
//! Usage in platform.zig:
//!
//! ```zig
//! const build_options = @import("build_options");
//! const websim = @import("websim");
//!
//! const hw = switch (build_options.board) {
//!     .korvo2_v3 => @import("esp/korvo2_v3.zig"),
//!     .websim => websim.mirror(@import("esp/korvo2_v3.zig")),
//! };
//! ```
//!
//! The mirror preserves all spec metadata (ranges, ref_values, meta IDs)
//! but replaces each Driver with the corresponding WebSim simulation driver.

const std = @import("std");
const state_mod = @import("impl/state.zig");
const drivers = @import("impl/drivers.zig");
const wifi_mod = @import("impl/wifi.zig");
const net_mod = @import("impl/net.zig");
const speaker_mod = @import("impl/speaker.zig");
const mic_mod = @import("impl/mic.zig");
const ble_mod = @import("impl/ble.zig");
const kvs_mod = @import("impl/kvs.zig");
const audio_system_mod = @import("impl/audio_system.zig");
const led_single_mod = @import("impl/led_single.zig");
const temp_sensor_mod = @import("impl/temp_sensor.zig");
const imu_mod = @import("impl/imu.zig");

const shared = &state_mod.state;

/// Create a WebSim mirror of a real board hw module.
/// Preserves all spec metadata, replaces Drivers with WebSim implementations.
pub fn mirror(comptime RealHw: type) type {
    return struct {
        // ================================================================
        // Platform primitives (always provided by WebSim)
        // ================================================================

        pub const log = drivers.sal.log;
        pub const time = drivers.sal.time;

        pub fn isRunning() bool {
            return drivers.sal.isRunning();
        }

        // ================================================================
        // Hardware info (mirror from real board if available)
        // ================================================================

        pub const Hardware = struct {
            pub const name = if (@hasDecl(RealHw, "Hardware") and @hasDecl(RealHw.Hardware, "name"))
                RealHw.Hardware.name ++ " (WebSim)"
            else
                "WebSim Board";

            pub const serial_port = "websim";
            pub const sample_rate: u32 = if (@hasDecl(RealHw, "Hardware") and @hasDecl(RealHw.Hardware, "sample_rate"))
                RealHw.Hardware.sample_rate
            else
                16000;
        };

        // ================================================================
        // RTC spec (always available in WebSim)
        // ================================================================

        pub const RtcDriver = drivers.RtcDriver;

        pub const rtc_spec = struct {
            pub const Driver = drivers.RtcDriver;
            pub const meta = if (@hasDecl(RealHw, "rtc_spec") and @hasDecl(RealHw.rtc_spec, "meta"))
                RealHw.rtc_spec.meta
            else
                .{ .id = "rtc" };
        };

        // ================================================================
        // LED spec
        // ================================================================

        pub const LedDriver = if (@hasDecl(RealHw, "led_spec"))
            drivers.LedDriver
        else
            void;

        pub const led_spec = if (@hasDecl(RealHw, "led_spec")) mirrorSpec(RealHw.led_spec, drivers.LedDriver) else void;

        // ================================================================
        // Button group spec (ADC buttons)
        // ================================================================

        pub const button_group_spec = if (@hasDecl(RealHw, "button_group_spec"))
            mirrorButtonGroupSpec(RealHw.button_group_spec)
        else
            void;

        // ================================================================
        // WiFi spec
        // ================================================================

        pub const wifi_spec = if (@hasDecl(RealHw, "wifi_spec")) mirrorSpec(RealHw.wifi_spec, wifi_mod.WifiDriver) else void;

        // ================================================================
        // Net spec
        // ================================================================

        pub const net_spec = if (@hasDecl(RealHw, "net_spec")) mirrorSpec(RealHw.net_spec, net_mod.NetDriver) else void;

        // ================================================================
        // Speaker spec
        // ================================================================

        pub const speaker_spec = if (@hasDecl(RealHw, "speaker_spec"))
            mirrorSpeakerSpec(RealHw.speaker_spec)
        else
            void;

        // ================================================================
        // Mic spec
        // ================================================================

        pub const mic_spec = if (@hasDecl(RealHw, "mic_spec"))
            mirrorMicSpec(RealHw.mic_spec)
        else
            void;

        // ================================================================
        // BLE spec
        // ================================================================

        pub const ble_spec = if (@hasDecl(RealHw, "ble_spec")) mirrorSpec(RealHw.ble_spec, ble_mod.BleDriver) else void;

        // ================================================================
        // KVS spec
        // ================================================================

        pub const kvs_spec = if (@hasDecl(RealHw, "kvs_spec")) mirrorSpec(RealHw.kvs_spec, kvs_mod.KvsDriver) else void;

        // ================================================================
        // AudioSystem + PA switch (for aec_test etc.)
        // ================================================================

        pub const AudioSystem = audio_system_mod.AudioSystem;
        pub const PaSwitchDriver = audio_system_mod.PaSwitchDriver;

        // ================================================================
        // Button spec (single GPIO button)
        // ================================================================

        pub const button_spec = if (@hasDecl(RealHw, "button_spec")) mirrorSpec(RealHw.button_spec, drivers.ButtonDriver) else void;

        // ================================================================
        // Power button spec
        // ================================================================

        pub const power_button_spec = if (@hasDecl(RealHw, "power_button_spec")) mirrorSpec(RealHw.power_button_spec, drivers.PowerButtonDriver) else void;

        // ================================================================
        // Single LED spec (PWM)
        // ================================================================

        pub const single_led_spec = if (@hasDecl(RealHw, "single_led_spec")) mirrorSpec(RealHw.single_led_spec, led_single_mod.LedSingleDriver) else void;

        // ================================================================
        // Temperature sensor spec
        // ================================================================

        pub const temp_sensor_spec = if (@hasDecl(RealHw, "temp_sensor_spec")) mirrorSpec(RealHw.temp_sensor_spec, temp_sensor_mod.TempSensorDriver) else void;

        // ================================================================
        // IMU spec
        // ================================================================

        pub const imu_spec = if (@hasDecl(RealHw, "imu_spec")) mirrorSpec(RealHw.imu_spec, imu_mod.ImuDriver) else void;
    };
}

/// Mirror a simple spec: replace Driver, keep meta.
fn mirrorSpec(comptime RealSpec: type, comptime WebSimDriver: type) type {
    return struct {
        pub const Driver = WebSimDriver;
        pub const meta = if (@hasDecl(RealSpec, "meta")) RealSpec.meta else .{ .id = "unknown" };
    };
}

/// Mirror button_group_spec: replace Driver with WebSim ADC driver, keep ranges and thresholds.
fn mirrorButtonGroupSpec(comptime RealSpec: type) type {
    return struct {
        pub const Driver = drivers.AdcButtonDriver;

        pub const ranges = if (@hasDecl(RealSpec, "ranges")) RealSpec.ranges else &[_]@import("hal").button_group.Range{};
        pub const ref_value: u16 = if (@hasDecl(RealSpec, "ref_value")) RealSpec.ref_value else 4095;
        pub const ref_tolerance: u16 = if (@hasDecl(RealSpec, "ref_tolerance")) RealSpec.ref_tolerance else 500;
        pub const meta = if (@hasDecl(RealSpec, "meta")) RealSpec.meta else .{ .id = "buttons.adc" };
    };
}

/// Mirror speaker spec: replace Driver, keep config.
fn mirrorSpeakerSpec(comptime RealSpec: type) type {
    const hal = @import("hal");
    return struct {
        pub const Driver = speaker_mod.SpeakerDriver;
        pub const meta = if (@hasDecl(RealSpec, "meta")) RealSpec.meta else .{ .id = "speaker" };
        pub const config = if (@hasDecl(RealSpec, "config"))
            RealSpec.config
        else
            hal.mono_speaker.Config{ .sample_rate = 16000, .bits_per_sample = 16 };
    };
}

/// Mirror mic spec: replace Driver, keep config.
fn mirrorMicSpec(comptime RealSpec: type) type {
    const hal = @import("hal");
    return struct {
        pub const Driver = mic_mod.MicDriver;
        pub const meta = if (@hasDecl(RealSpec, "meta")) RealSpec.meta else .{ .id = "mic" };
        pub const config = if (@hasDecl(RealSpec, "config"))
            RealSpec.config
        else
            hal.mic.Config{ .sample_rate = 16000, .channels = 1, .bits_per_sample = 16 };
    };
}
