//! websim - Browser-based Hardware Simulator (WASM)
//!
//! A platform implementation that compiles Zig apps to WebAssembly
//! and runs them in the browser with an HTML/JS shell.
//!
//! ## Architecture
//!
//! Zig app (WASM) ← JS calls step() each frame
//!   → HAL drivers read/write SharedState
//!     → JS reads SharedState from WASM linear memory
//!       → Updates DOM (LED, canvas, log)
//!
//! ## Usage (board definition)
//!
//! ```zig
//! const websim = @import("websim");
//!
//! pub const button_spec = struct {
//!     pub const Driver = websim.ButtonDriver;
//!     pub const meta = .{ .id = "button.boot" };
//! };
//!
//! pub const led_spec = struct {
//!     pub const Driver = websim.LedDriver;
//!     pub const meta = .{ .id = "led.main" };
//! };
//!
//! pub const log = websim.sal.log;
//! pub const time = websim.sal.time;
//! pub const isRunning = websim.sal.isRunning;
//! ```

pub const drivers = @import("impl/drivers.zig");
pub const state_mod = @import("impl/state.zig");
pub const spi_sim = @import("impl/spi.zig");
pub const kvs_mod = @import("impl/kvs.zig");
pub const wifi_mod = @import("impl/wifi.zig");
pub const net_mod = @import("impl/net.zig");
pub const speaker_mod = @import("impl/speaker.zig");
pub const mic_mod = @import("impl/mic.zig");
pub const ble_mod = @import("impl/ble.zig");
pub const audio_system_mod = @import("impl/audio_system.zig");
pub const led_single_mod = @import("impl/led_single.zig");
pub const temp_sensor_mod = @import("impl/temp_sensor.zig");
pub const imu_mod = @import("impl/imu.zig");
const builtin = @import("builtin");

pub const wasm = @import("wasm/wasm.zig");
pub const native = if (builtin.target.cpu.arch == .wasm32)
    @compileError("native module not available on WASM target — use wasm module instead")
else
    @import("native/native.zig");
pub const boards = @import("boards/boards.zig");
pub const mirror_mod = @import("mirror.zig");

/// Create a WebSim mirror of any real board hw module.
/// Usage: `const hw = websim.mirror(@import("esp/korvo2_v3.zig"));`
pub fn mirror(comptime RealHw: type) type {
    return mirror_mod.mirror(RealHw);
}

// Re-export driver types for board definitions
pub const RtcDriver = drivers.RtcDriver;
pub const ButtonDriver = drivers.ButtonDriver;
pub const PowerButtonDriver = drivers.PowerButtonDriver;
pub const AdcButtonDriver = drivers.AdcButtonDriver;
pub const LedDriver = drivers.LedDriver;
pub const KvsDriver = kvs_mod.KvsDriver;
pub const WifiDriver = wifi_mod.WifiDriver;
pub const NetDriver = net_mod.NetDriver;
pub const SpeakerDriver = speaker_mod.SpeakerDriver;
pub const MicDriver = mic_mod.MicDriver;
pub const BleDriver = ble_mod.BleDriver;
pub const AudioSystem = audio_system_mod.AudioSystem;
pub const PaSwitchDriver = audio_system_mod.PaSwitchDriver;
pub const LedSingleDriver = led_single_mod.LedSingleDriver;
pub const TempSensorDriver = temp_sensor_mod.TempSensorDriver;
pub const ImuDriver = imu_mod.ImuDriver;
pub const sal = drivers.sal;

// Re-export simulated SPI types (for display)
pub const SimSpi = spi_sim.SimSpi;
pub const SimDcPin = spi_sim.SimDcPin;

// Re-export state types
pub const SharedState = state_mod.SharedState;
pub const Color = state_mod.Color;
pub const MAX_LEDS = state_mod.MAX_LEDS;
pub const DISPLAY_WIDTH = state_mod.DISPLAY_WIDTH;
pub const DISPLAY_HEIGHT = state_mod.DISPLAY_HEIGHT;

/// Global shared state (accessible from drivers and WASM exports)
pub const shared = &state_mod.state;
