//! ESP-IDF Low-level Bindings
//!
//! Provides idiomatic Zig wrappers for ESP-IDF C APIs.
//! This is the low-level layer - for trait/hal implementations, use lib/esp/impl.
//!
//! ## Modules
//!
//! | Category | Module | Description |
//! |----------|--------|-------------|
//! | Core | sys | Error types and ESP error conversion |
//! | Core | heap | Memory allocators (psram, iram, dma) |
//! | Core | rtos | FreeRTOS task delay |
//! | Core | task | Task management |
//! | Core | event | Default event loop |
//! | GPIO | gpio | General Purpose I/O |
//! | ADC | adc | ADC and temperature sensor |
//! | PWM | ledc | LED Control (PWM) |
//! | PWM | pwm | High-level PWM wrapper |
//! | Timer | timer | Hardware timers |
//! | Storage | nvs | Non-volatile storage |
//! | Network | net | DNS resolver, socket |
//! | Network | http | HTTP client |
//! | Network | socket | LWIP socket wrapper |
//! | Network | tls | mbedTLS wrapper |
//! | WiFi | wifi | WiFi station mode |
//! | Audio | mic | I2S microphone |
//! | Audio | i2s_tdm | I2S TDM mode |
//! | LED | led_strip | WS2812/SK6812 LED strip |
//! | Bus | i2c | I2C master |
//! | Sync | sync | Mutex, Semaphore, Event |
//! | Sync | queue | FreeRTOS queue |
//! | Async | runtime | Mutex, Condition, spawn (for pkg/channel, pkg/waitgroup) |
//! | Thread | (removed — use runtime.Thread) |
//! | Time | time | Sleep, timestamps |
//! | Log | log | ESP logging |

// ============================================================================
// Core
// ============================================================================

pub const sys = @import("sys.zig");
pub const EspError = sys.EspError;
pub const espErrToZig = sys.espErrToZig;

pub const heap = @import("heap.zig");
pub const rtos = @import("rtos.zig");
pub const delayMs = rtos.delayMs;
pub const task = @import("task.zig");
pub const random = @import("random.zig");
pub const event = @import("event/event.zig");

// ============================================================================
// GPIO & Peripherals
// ============================================================================

pub const gpio = @import("gpio.zig");
pub const adc = @import("adc.zig");
pub const AdcOneshot = adc.AdcOneshot;
pub const TempSensor = adc.TempSensor;

// ============================================================================
// PWM
// ============================================================================

pub const ledc = @import("ledc/ledc.zig");
pub const Ledc = ledc.Ledc;
pub const pwm = @import("pwm.zig");
pub const Pwm = pwm.Pwm;

// ============================================================================
// Timer
// ============================================================================

pub const timer = @import("timer/timer.zig");
pub const Timer = timer.Timer;

// ============================================================================
// Storage
// ============================================================================

pub const nvs = @import("nvs.zig");
pub const Nvs = nvs.Nvs;

// ============================================================================
// Network
// ============================================================================

pub const net = @import("net.zig");
pub const DnsResolver = net.DnsResolver;
pub const http = @import("http.zig");
pub const HttpClient = http.HttpClient;
pub const socket = @import("net/socket.zig");
pub const Socket = socket.Socket;
pub const mbed_tls = @import("mbed_tls.zig");

// ============================================================================
// WiFi
// ============================================================================

pub const wifi = @import("wifi/wifi.zig");
pub const Wifi = wifi.Wifi; // Legacy API
pub const WifiMode = wifi.Mode;
pub const WifiStaConfig = wifi.StaConfig;
pub const WifiApConfig = wifi.ApConfig;

// ============================================================================
// Bluetooth
// ============================================================================

pub const bt = @import("bt/bt.zig");

// ============================================================================
// Audio
// ============================================================================

pub const mic = @import("mic.zig");
pub const Mic = mic.Mic;
pub const MicConfig = mic.Config;
pub const ChannelRole = mic.ChannelRole;
pub const i2s_tdm = @import("i2s_tdm.zig");
pub const I2sTdm = i2s_tdm.I2sTdm;
pub const i2s = @import("i2s.zig");
pub const I2s = i2s.I2s;
pub const speaker = @import("speaker.zig");
pub const Speaker = speaker.Speaker;
pub const sr = @import("sr/aec.zig");
pub const Aec = sr.Aec;

// ============================================================================
// LED Strip
// ============================================================================

pub const led_strip = @import("led_strip.zig");
pub const LedStrip = led_strip.LedStrip;

// ============================================================================
// Bus
// ============================================================================

pub const i2c = @import("i2c/i2c.zig");
pub const I2c = i2c.I2c;

// ============================================================================
// Synchronization (FreeRTOS)
// ============================================================================

pub const sync = @import("sync.zig");
pub const Mutex = sync.Mutex;
pub const Semaphore = sync.Semaphore;
pub const Event = sync.Event;
pub const queue = @import("queue.zig");
pub const Queue = queue.Queue;

// ============================================================================
// Async & Threading (FreeRTOS)
// ============================================================================

pub const runtime = @import("runtime.zig");
pub const time = @import("time.zig");
pub const sleepMs = time.sleepMs;
pub const nowMs = time.nowMs;
pub const nowUs = time.nowUs;
pub const Deadline = time.Deadline;
pub const Stopwatch = time.Stopwatch;

// ============================================================================
// Logging
// ============================================================================

pub const log = @import("log.zig");

// ============================================================================
// Tests
// ============================================================================

test {
    @import("std").testing.refAllDecls(@This());
}
