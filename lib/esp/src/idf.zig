//! ESP-IDF Zig bindings
//!
//! Usage:
//!   const idf = @import("esp_zig").idf;
//!   const sal = idf.sal;
//!   const heap = idf.heap;
//!
//!   // SAL thread with PSRAM stack
//!   const result = try sal.thread.go(heap.psram, "worker", myFn, null, .{
//!       .stack_size = 65536,
//!   });
//!
//!   // SAL mutex
//!   var mutex = sal.Mutex.init();
//!   defer mutex.deinit();

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
pub const sys = @import("sys.zig");
pub const EspError = sys.EspError;
pub const task = @import("task.zig");
pub const timer = @import("timer/timer.zig");
pub const Timer = timer.Timer;
pub const wifi = @import("wifi/wifi.zig");
pub const Wifi = wifi.Wifi;

// SAL - System Abstraction Layer
// GPIO & Peripherals
// LED Strip
// Storage
// Network
test {
    @import("std").testing.refAllDecls(@This());
}
