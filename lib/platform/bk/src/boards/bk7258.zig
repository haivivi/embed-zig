//! Hardware Definition & Drivers: BK7258
//!
//! BK7258 is a dual-core ARM Cortex-M33 SoC (CP + AP).
//! CP runs WiFi/BLE/drivers, AP runs user applications.
//!
//! Usage:
//!   const board = @import("bk").boards.bk7258;
//!   pub const log = board.log;
//!   pub const time = board.time;

const std = @import("std");
const armino = @import("../../armino/src/armino.zig");
const impl = @import("../../impl/src/impl.zig");

// ============================================================================
// Board Identification
// ============================================================================

/// Board name
pub const name = "BK7258";

/// Serial port for flashing
pub const serial_port = "/dev/cu.usbserial-130";

// ============================================================================
// Platform Primitives
// ============================================================================

/// Scoped logger
pub const log = impl.log.scoped("app");

/// Time utilities
pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        impl.Time.sleepMs(ms);
    }

    pub fn getTimeMs() u64 {
        return impl.Time.getTimeMs();
    }
};

/// Check if board is still running (always true for BK, no graceful shutdown)
pub fn isRunning() bool {
    return true;
}

// ============================================================================
// Audio Configuration (BK7258 Onboard DAC)
// ============================================================================

/// BK7258 uses onboard DAC for speaker output (not I2S + external DAC).
/// Audio pipeline: raw_stream -> onboard_speaker_stream -> DAC
pub const audio = struct {
    pub const sample_rate: u32 = 8000;
    pub const channels: u8 = 1;
    pub const bits: u8 = 16;
    pub const dig_gain: u8 = 0x2d; // 0dB
    pub const ana_gain: u8 = 0x0A;
};
