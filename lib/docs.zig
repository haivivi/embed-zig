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
//! - **HTTP**: HTTP client (esp_http_client)
//! - **NVS**: Non-volatile storage
//! - **Timer**: Hardware timers
//! - **LED Strip**: Addressable LED control
//! - **ADC**: Analog-to-digital conversion
//! - **LEDC**: PWM generation
//!
//! ### System Abstraction Layer (`sal`)
//!
//! Cross-platform interface definitions for:
//! - **Thread**: Task/thread management
//! - **Sync**: Mutex, Semaphore, Event
//! - **Time**: Sleep and delay functions
//! - **Queue**: Thread-safe message queues
//! - **Socket**: TCP/UDP networking
//! - **TLS**: Secure connections
//! - **I2C**: I2C bus communication
//!
//! ### Hardware Abstraction Layer (`hal`)
//!
//! Unified hardware interface across different boards:
//! - **Board**: Generic board abstraction with event system
//! - **Button**: GPIO, ADC, and touch button abstractions
//! - **LED Strip**: Addressable LED control with animations
//! - **Event**: Type-safe hardware event system
//!
//! ### HTTP Client (`http`)
//!
//! Platform-independent HTTP/1.1 client:
//! - HTTP and HTTPS support
//! - DNS resolution integration
//! - Works with any SAL socket implementation
//!
//! ### DNS Resolver (`dns`)
//!
//! Cross-platform DNS resolution:
//! - UDP and TCP protocols
//! - DNS over HTTPS (DoH) support
//!
//! ### Device Drivers (`drivers`)
//!
//! Platform-independent device drivers:
//! - **TCA9554**: I2C GPIO expander
//!
//! ### Input Handling (`input`)
//!
//! Input device abstractions:
//! - **ADC Button**: Multi-button input via resistor ladder
//! - Press/release, long press, multi-click detection
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
//! // HAL board event loop
//! while (board.nextEvent()) |event| {
//!     switch (event) {
//!         .button => |btn| handleButton(btn),
//!         else => {},
//!     }
//! }
//!
//! // HTTP client
//! const HttpClient = embed.http.Client(Socket);
//! var client = HttpClient{};
//! const resp = try client.get("http://example.com/api", &buffer);
//! ```

/// ESP-IDF Zig Bindings
///
/// Provides idiomatic Zig wrappers for ESP-IDF C APIs.
/// Includes GPIO, WiFi, HTTP, NVS, Timer, LED Strip, ADC, LEDC, and more.
pub const esp = @import("esp/src/idf.zig");

/// System Abstraction Layer (Interface)
///
/// Cross-platform interface definitions for threading, synchronization,
/// time management, queues, sockets, and TLS.
/// Use with platform-specific implementations (esp impl or std_impl).
pub const sal = @import("sal/src/sal.zig");

/// Hardware Abstraction Layer
///
/// Unified hardware interface for boards with compile-time configuration.
/// Provides type-safe abstractions for buttons, LEDs, and other peripherals
/// with a generic event system.
pub const hal = @import("hal/src/hal.zig");

/// HTTP Client Library
///
/// Platform-independent HTTP/1.1 client supporting HTTP, HTTPS,
/// and DNS resolution. Works with any SAL socket implementation.
pub const http = @import("http/src/http.zig");

/// DNS Resolver
///
/// Cross-platform DNS resolution supporting UDP, TCP, and DoH protocols.
/// Generic over socket type for platform independence.
pub const dns = @import("dns/src/dns.zig");

/// Device Drivers
///
/// Platform-independent device drivers that work with abstract interfaces
/// (I2C, SPI) rather than platform-specific implementations.
pub const drivers = @import("drivers/src/drivers.zig");

/// Input Handling
///
/// Input device abstractions including ADC button sets with
/// debouncing, long press, and multi-click detection.
pub const input = struct {
    pub const adc_button = @import("input/src/adc_button.zig");
    pub const AdcButtonSet = adc_button.AdcButtonSet;
    pub const ButtonEvents = adc_button.ButtonEvents;
};

test {
    @import("std").testing.refAllDecls(@This());
}
