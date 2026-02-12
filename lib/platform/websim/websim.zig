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
pub const wasm = @import("wasm/wasm.zig");
pub const boards = @import("boards/boards.zig");

// Re-export driver types for board definitions
pub const RtcDriver = drivers.RtcDriver;
pub const ButtonDriver = drivers.ButtonDriver;
pub const PowerButtonDriver = drivers.PowerButtonDriver;
pub const AdcButtonDriver = drivers.AdcButtonDriver;
pub const LedDriver = drivers.LedDriver;
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
