//! ESP32 Implementations of trait and hal interfaces
//!
//! This module provides ESP32-specific implementations that can be used with
//! the trait and hal interface validators.
//!
//! ## trait implementations
//!
//! | Module | Interface | Description |
//! |--------|-----------|-------------|
//! | socket | trait.socket | LWIP TCP/UDP sockets |
//! | time | trait.time | FreeRTOS + esp_timer |
//! | i2c | trait.i2c | ESP-IDF I2C master |
//! | log | trait.log | ESP-IDF esp_log |
//!
//! ## hal implementations (Drivers)
//!
//! | Module | Interface | Description |
//! |--------|-----------|-------------|
//! | wifi | hal.wifi | ESP-IDF WiFi station |
//! | kvs | hal.kvs | ESP-IDF NVS storage |
//! | mic | hal.mic | I2S microphone |
//! | led_strip | hal.led_strip | WS2812/SK6812 LED strip |
//! | led | hal.led | LEDC PWM single LED |
//! | button | hal.button | GPIO button |
//! | button_group | hal.button_group | ADC button ladder |
//! | rtc | hal.rtc | RTC reader/writer |
//! | temp_sensor | hal.temp_sensor | Internal temp sensor |
//!
//! ## Usage
//!
//! ```zig
//! const impl = @import("impl");
//! const trait = @import("trait");
//! const hal = @import("hal");
//!
//! // Use trait implementations
//! const Socket = trait.socket.from(impl.Socket);
//! const Time = trait.time.from(impl.Time);
//!
//! // Use hal implementations
//! const wifi_spec = struct {
//!     pub const Driver = impl.WifiDriver;
//!     pub const meta = .{ .id = "wifi.main" };
//! };
//! const Wifi = hal.wifi.from(wifi_spec);
//! ```

// ============================================================================
// trait implementations
// ============================================================================

/// Socket implementation (trait.socket)
pub const socket = @import("socket.zig");
pub const Socket = socket.Socket;

/// Time implementation (trait.time)
pub const time = @import("time.zig");
pub const Time = time.Time;

/// I2C implementation (trait.i2c)
pub const i2c = @import("i2c.zig");
pub const I2c = i2c.I2c;

/// Log implementation (trait.log)
pub const log = @import("log.zig");
pub const Log = log.Log;
pub const stdLogFn = log.stdLogFn;

/// Crypto implementation (trait.crypto) - mbedTLS hardware accelerated
pub const crypto = @import("crypto/suite.zig");

/// Codec implementation (trait.codec) - opus with FIXED_POINT, PSRAM
pub const codec = struct {
    pub const opus = @import("codec/opus.zig");
};

/// Net implementation (hal.net) - network interface
pub const net = @import("net.zig");
pub const NetDriver = net.NetDriver;

// ============================================================================
// hal implementations (Drivers)
// ============================================================================

/// WiFi drivers (hal.wifi)
pub const wifi = @import("wifi.zig");
pub const WifiDriver = wifi.WifiDriver; // Legacy alias for StaDriver
pub const WifiStaDriver = wifi.StaDriver;
pub const WifiApDriver = wifi.ApDriver;

/// KVS driver (hal.kvs)
pub const kvs = @import("kvs.zig");
pub const KvsDriver = kvs.KvsDriver;

/// Microphone driver (hal.mic)
pub const mic = @import("mic.zig");
pub const MicDriver = mic.MicDriver;

/// LED strip driver (hal.led_strip)
pub const led_strip = @import("led_strip.zig");
pub const LedStripDriver = led_strip.LedStripDriver;

/// LED driver (hal.led)
pub const led = @import("led.zig");
pub const LedDriver = led.LedDriver;

/// Button driver (hal.button)
pub const button = @import("button.zig");
pub const ButtonDriver = button.ButtonDriver;

/// Button group driver (hal.button_group)
pub const button_group = @import("button_group.zig");
pub const ButtonGroupDriver = button_group.ButtonGroupDriver;

/// RTC drivers (hal.rtc)
pub const rtc = @import("rtc.zig");
pub const RtcReaderDriver = rtc.RtcReaderDriver;
pub const RtcWriterDriver = rtc.RtcWriterDriver;

/// Temperature sensor driver (hal.temp_sensor)
pub const temp_sensor = @import("temp_sensor.zig");
pub const TempSensorDriver = temp_sensor.TempSensorDriver;

/// Audio system with AEC (ES8311 + ES7210)
pub const audio_system = @import("audio_system.zig");
pub const AudioSystem = audio_system.AudioSystem;

/// HCI transport driver (hal.hci) — ESP VHCI
pub const hci = @import("hci.zig");
pub const HciDriver = hci.HciDriver;

// ============================================================================
// Tests
// ============================================================================

test {
    @import("std").testing.refAllDecls(@This());
}
