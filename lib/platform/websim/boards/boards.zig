//! WebSim Board Definitions
//!
//! Pre-configured board layouts for the browser simulator.

pub const basic = @import("basic.zig");
pub const standard = @import("standard.zig");

// Re-export standard board types for convenience
pub const ButtonId = standard.ButtonId;
pub const adc_ranges = standard.adc_ranges;
pub const adc_values = standard.adc_values;

pub const rtc_spec = standard.rtc_spec;
pub const power_button_spec = standard.power_button_spec;
pub const adc_button_spec = standard.adc_button_spec;
pub const led_spec = standard.led_spec;
pub const display_spec = standard.display_spec;
pub const log = standard.log;
pub const time = standard.time;
pub const isRunning = standard.isRunning;
