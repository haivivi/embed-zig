//! HAL - Hardware Abstraction Layer
//!
//! A unified interface for hardware access across different boards.
//! Provides type-safe, compile-time configured abstractions.
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   board.led.setColor(Color.red)         │
//! │   board.nextEvent() -> button, wifi, net, motion         │
//! ├─────────────────────────────────────────┤
//! │ hal.Board(spec) - Auto-generated        │
//! │   - Event queue management              │
//! │   - Driver lifecycle                    │
//! │   - Background tasks for buttons/motion                     │
//! ├─────────────────────────────────────────┤
//! │ HAL Components                          │
//! │   LedStrip(spec)                        │
//! │   Button(spec)                          │
//! │   ButtonGroup(spec, ButtonId)           │
//! ├─────────────────────────────────────────┤
//! │ Drivers (board implementation)          │
//! │   WS2812Driver, AdcReader, etc.         │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // board.zig
//! const hal = @import("hal");
//! const hw = @import("korvo2_v3.zig");
//!
//! pub const ButtonId = enum { vol_up, vol_down, play };
//!
//! pub const spec = struct {
//!     pub const buttons = hal.ButtonGroup(hw.button_spec, ButtonId);
//!     pub const rgb_leds = hal.RgbLedStrip(hw.led_spec);
//!     pub const getTimeFn = hw.getTimeFn;
//! };
//!
//! pub const Board = hal.Board(spec);
//!
//! // main.zig
//! var board = try Board.init();
//! // Poll peripherals (events pushed directly to board queue via callbacks)
//! board.buttons.poll();  // For button groups
//! board.motion.poll();   // For motion detection
//! // Process events from unified queue
//! while (board.nextEvent()) |event| { ... }
//! board.led.setColor(hal.Color.red);
//! ```

// ============================================================================
// Core Types
// ============================================================================

/// Board - auto-manages drivers and events from spec
pub const Board = @import("board.zig").Board;
/// Simple event queue
pub const SimpleQueue = @import("board.zig").SimpleQueue;

// ============================================================================
// Trait Module (re-exported for convenience)
// ============================================================================

/// Trait interfaces (log, time, etc.)
pub const trait = @import("trait");

// ============================================================================
// HAL Components
// ============================================================================

/// RGB LED Strip module (hal.led_strip.from, hal.led_strip.is)
pub const led_strip = @import("led_strip.zig");
/// Single Button module (hal.button.from, hal.button.is)
pub const button = @import("button.zig");
/// Button Group module (hal.button_group.from, hal.button_group.is)
pub const button_group = @import("button_group.zig");
/// WiFi module (hal.wifi.from, hal.wifi.is)
pub const wifi = @import("wifi.zig");
/// Net module (hal.net.from, hal.net.is)
pub const net = @import("net.zig");
/// RTC module (hal.rtc.reader.from, hal.rtc.writer.from)
pub const rtc = @import("rtc.zig");
/// Single LED module (hal.led.from, hal.led.is)
pub const led = @import("led.zig");
/// Temperature Sensor module (hal.temp_sensor.from, hal.temp_sensor.is)
pub const temp_sensor = @import("temp_sensor.zig");
/// Key-Value Store module (hal.kvs.from, hal.kvs.is)
pub const kvs = @import("kvs.zig");
/// Microphone module (hal.mic.from, hal.mic.is)
pub const mic = @import("mic.zig");
/// Mono Speaker module (hal.mono_speaker.from, hal.mono_speaker.is)
pub const mono_speaker = @import("mono_speaker.zig");
/// Switch module (hal.switch_.from, hal.switch_.is)
pub const switch_ = @import("switch.zig");
/// IMU module (hal.imu.from, hal.imu.is)
pub const imu = @import("imu.zig");
/// Motion detection module (hal.motion.from, hal.motion.is)
pub const motion = @import("motion.zig");
/// HCI transport module (hal.hci.from, hal.hci.is)
pub const hci = @import("hci.zig");
/// BLE Host module (hal.ble.from, hal.ble.is)
pub const ble = @import("ble.zig");
/// Timer module (hal.timer.from, hal.timer.is)
pub const timer = @import("timer.zig");

// ============================================================================
// Common Types
// ============================================================================

/// RGB Color
pub const Color = @import("led_strip.zig").Color;
/// Button action types
pub const ButtonAction = @import("button.zig").ButtonAction;

// ============================================================================
// Event Types
// ============================================================================

/// System events
pub const SystemEvent = @import("event.zig").SystemEvent;
/// Timer events
pub const TimerEvent = @import("event.zig").TimerEvent;

// ============================================================================
// RTC Types
// ============================================================================

/// Unix timestamp with utilities
pub const Timestamp = @import("rtc.zig").Timestamp;
/// Datetime components
pub const Datetime = @import("rtc.zig").Datetime;

// ============================================================================
// Button Types
// ============================================================================

/// Button configuration
pub const ButtonConfig = @import("button.zig").ButtonConfig;
/// Button group configuration
pub const ButtonGroupConfig = @import("button_group.zig").ButtonGroupConfig;
/// ADC range for button group
pub const ButtonGroupRange = @import("button_group.zig").Range;

// ============================================================================
// LED Animation Types
// ============================================================================

/// Animation container
pub const Animation = @import("led_strip.zig").Animation;
/// Keyframe for animations
pub const Keyframe = @import("led_strip.zig").Keyframe;
/// Easing curves
pub const Easing = @import("led_strip.zig").Easing;
/// Effect generators
pub const Effects = @import("led_strip.zig").Effects;

// ============================================================================
// WiFi Types
// ============================================================================

const wifi_mod = @import("wifi.zig");
pub const IpAddress = wifi_mod.IpAddress;
pub const Mac = wifi_mod.Mac;
pub const WifiState = wifi_mod.State;
pub const WifiEvent = wifi_mod.WifiEvent;
pub const WifiDisconnectReason = wifi_mod.DisconnectReason;
pub const WifiFailReason = wifi_mod.FailReason;
pub const WifiConnectConfig = wifi_mod.ConnectConfig;
pub const WifiStatus = wifi_mod.Status;

// ============================================================================
// Net Types
// ============================================================================

const net_mod = @import("net.zig");
pub const Ipv4 = net_mod.Ipv4;
pub const NetIfState = net_mod.NetIfState;
pub const NetIfInfo = net_mod.NetIfInfo;
pub const NetEvent = net_mod.NetEvent;
pub const DhcpBoundData = net_mod.DhcpBoundData;
pub const DhcpMode = net_mod.DhcpMode;

/// Event module
pub const event = @import("event.zig");

// ============================================================================
// Tests
// ============================================================================

// ============================================================================
// Microphone Types
// ============================================================================

/// Microphone configuration
pub const MicConfig = mic.Config;
/// Microphone sample format
pub const MicSampleFormat = mic.SampleFormat;

// ============================================================================
// MonoSpeaker Types
// ============================================================================

/// MonoSpeaker configuration
pub const MonoSpeakerConfig = mono_speaker.Config;

// ============================================================================
// IMU Types
// ============================================================================

/// IMU accelerometer data
pub const AccelData = imu.AccelData;
/// IMU gyroscope data
pub const GyroData = imu.GyroData;
/// IMU magnetometer data
pub const MagData = imu.MagData;

// ============================================================================
// Motion Types
// ============================================================================

/// Motion event payload for board.Event
pub const MotionEventPayload = motion.MotionEventPayload;
/// Motion axis
pub const MotionAxis = motion.Axis;
/// Motion orientation
pub const MotionOrientation = motion.Orientation;

// ============================================================================
// HCI Types
// ============================================================================

/// HCI poll flags
pub const HciPollFlags = hci.PollFlags;
/// HCI packet type indicator
pub const HciPacketType = hci.PacketType;
/// HCI transport error
pub const HciError = hci.Error;

// ============================================================================
// BLE Types
// ============================================================================

// ============================================================================
// Timer Types
// ============================================================================

/// Timer handle for cancellation
pub const TimerHandle = timer.TimerHandle;
/// Timer callback type (same as spawner.TaskFn)
pub const TimerCallback = timer.Callback;

// ============================================================================
// BLE Types
// ============================================================================

/// BLE Host state
pub const BleState = ble.State;
/// BLE event
pub const BleEvent = ble.BleEvent;
/// BLE connection info
pub const BleConnectionInfo = ble.ConnectionInfo;
/// BLE advertising config
pub const BleAdvConfig = ble.AdvConfig;
/// BLE role
pub const BleRole = ble.Role;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("board.zig");
    _ = @import("button_group.zig");
    _ = @import("wifi.zig");
    _ = @import("net.zig");
    _ = @import("rtc.zig");
    _ = @import("led.zig");
    _ = @import("temp_sensor.zig");
    _ = @import("kvs.zig");
    _ = @import("mic.zig");
    _ = @import("mono_speaker.zig");
    _ = @import("switch.zig");
    _ = @import("imu.zig");
    _ = @import("motion.zig");
    _ = @import("hci.zig");
    _ = @import("ble.zig");
    _ = @import("timer.zig");
}
