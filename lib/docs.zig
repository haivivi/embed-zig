//! # embed-zig
//!
//! A collection of Zig libraries for embedded development.
//!
//! ## Libraries
//!
//! ### ESP-IDF Bindings (`esp`)
//!
//! Zig bindings for ESP-IDF APIs:
//! - **GPIO**: Digital I/O control
//! - **WiFi**: Station mode networking
//! - **HTTP**: HTTP client
//! - **NVS**: Non-volatile storage
//! - **Timer**: Hardware timers
//! - **LED Strip**: Addressable LED control
//! - **ADC**: Analog-to-digital conversion
//! - **LEDC**: PWM generation
//!
//! ### System Abstraction Layer (`sal`)
//!
//! Cross-platform abstractions:
//! - **Thread**: Task/thread management
//! - **Sync**: Mutex, Semaphore, Event
//! - **Time**: Sleep and delay functions
//!
//! ## Quick Start
//!
//! ```zig
//! const embed = @import("embed-zig");
//!
//! // GPIO example
//! try embed.esp.gpio.configOutput(48);
//! try embed.esp.gpio.setLevel(48, 1);
//!
//! // WiFi example
//! var wifi = try embed.esp.Wifi.init();
//! try wifi.connect(.{
//!     .ssid = "MyNetwork",
//!     .password = "secret",
//! });
//!
//! // SAL thread example
//! _ = try embed.sal.thread.go(allocator, "worker", myFn, null, .{});
//! ```

/// ESP-IDF Zig Bindings
///
/// Provides idiomatic Zig wrappers for ESP-IDF C APIs.
/// See individual modules for detailed documentation.
pub const esp = @import("esp/src/idf.zig");
/// System Abstraction Layer
///
/// Cross-platform abstractions for threading, synchronization,
/// and time management. Works on both ESP32 (FreeRTOS) and POSIX systems.
pub const sal = @import("sal/src/sal.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
