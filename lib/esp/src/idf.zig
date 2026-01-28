//! ESP-IDF Zig bindings
//!
//! Provides idiomatic Zig wrappers for ESP-IDF C APIs.
//! See individual modules for detailed documentation.

// Core
pub const adc = @import("adc.zig");
pub const AdcOneshot = adc.AdcOneshot;
pub const TempSensor = adc.TempSensor;
pub const gpio = @import("gpio.zig");
pub const heap = @import("heap.zig");
pub const http = @import("http.zig");
pub const HttpClient = http.HttpClient;
pub const led_strip = @import("led_strip.zig");
pub const LedStrip = led_strip.LedStrip;
pub const ledc = @import("ledc/ledc.zig");
pub const log = @import("log.zig");
pub const net = @import("net.zig");
pub const DnsResolver = net.DnsResolver;
pub const nvs = @import("nvs.zig");
pub const Nvs = nvs.Nvs;
pub const rtos = @import("rtos.zig");
pub const delayMs = rtos.delayMs;
pub const sal = @import("sal.zig");
pub const time = @import("sal/time.zig");
pub const nowMs = time.nowMs;
pub const nowUs = time.nowUs;
pub const sys = @import("sys.zig");
pub const EspError = sys.EspError;
pub const task = @import("task.zig");
pub const timer = @import("timer/timer.zig");
pub const Timer = timer.Timer;
pub const wifi = @import("wifi/wifi.zig");
pub const Wifi = wifi.Wifi;
pub const mic = @import("mic.zig");
pub const Mic = mic.Mic;
pub const MicConfig = mic.Config;
pub const ChannelRole = mic.ChannelRole;
pub const i2s_tdm = @import("i2s_tdm.zig");
pub const I2sTdm = i2s_tdm.I2sTdm;
pub const I2sTdmConfig = i2s_tdm.Config;

// Board definitions
pub const boards = struct {
    pub const korvo2_v3 = @import("boards/korvo2_v3.zig");
    pub const esp32s3_devkit = @import("boards/esp32s3_devkit.zig");
};

// SAL - System Abstraction Layer
// GPIO & Peripherals
// LED Strip
// Storage
// Network
test {
    @import("std").testing.refAllDecls(@This());
}
