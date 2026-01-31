//! Platform Configuration - AEC Test
//!
//! Supports: Korvo-2 V3 (ES7210 ADC + ES8311 DAC + AEC)
//!
//! Uses AudioSystem for unified mic+speaker with AEC.

const hal = @import("hal");
const hw = @import("boards/korvo2_v3.zig");

pub const Hardware = hw.Hardware;

// Re-export platform primitives
pub const log = hw.log;
pub const time = hw.time;
pub fn isRunning() bool {
    return hw.isRunning();
}

// Re-export AudioSystem and PaSwitchDriver
pub const AudioSystem = hw.AudioSystem;
pub const PaSwitchDriver = hw.PaSwitchDriver;

/// Board struct for AEC test (simplified, no HAL wrappers)
pub const Board = struct {
    const Self = @This();

    // Re-export for app.zig compatibility
    pub const log = hw.log;
    pub const time = hw.time;

    audio: AudioSystem,
    pa_switch: PaSwitchDriver,

    pub fn init(self: *Self) !void {
        // Initialize audio system (mic + speaker + AEC)
        self.audio = try AudioSystem.init();
        errdefer self.audio.deinit();

        // Initialize PA switch
        self.pa_switch = try PaSwitchDriver.init();
    }

    pub fn deinit(self: *Self) void {
        self.pa_switch.deinit();
        self.audio.deinit();
    }
};
