//! BK7258 Board Configuration for Speaker Test
//!
//! Uses onboard DAC via Armino audio pipeline (not I2S + external DAC).
//! No external PA switch — the onboard speaker stream handles DAC directly.

const std = @import("std");
const bk = @import("bk");

const board = bk.boards.bk7258;
const armino = bk.armino;

// Re-export platform primitives
pub const log = board.log;
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
    pub const sample_rate: u32 = board.audio.sample_rate;

    // BK7258 uses onboard DAC — no I2C/I2S pins needed
    pub const pa_enable_gpio: u8 = 0; // No external PA
};

// ============================================================================
// Drivers
// ============================================================================

pub const SpeakerDriver = struct {
    inner: armino.speaker.Speaker = .{},

    pub fn init() !SpeakerDriver {
        return .{ .inner = .{} };
    }

    pub fn initWithShared(self: *SpeakerDriver, _: anytype, _: anytype) !void {
        // BK7258 doesn't use shared I2C/I2S — init audio pipeline directly
        self.inner = try armino.speaker.Speaker.init(
            board.audio.sample_rate,
            board.audio.channels,
            board.audio.bits,
            board.audio.dig_gain,
        );
    }

    pub fn deinit(self: *SpeakerDriver) void {
        self.inner.deinit();
    }

    pub fn write(self: *SpeakerDriver, buffer: []const i16) !usize {
        return self.inner.write(buffer);
    }

    pub fn setVolume(self: *SpeakerDriver, volume: u8) !void {
        // Map 0-255 to DAC gain range 0x00-0x3F
        const gain: u8 = @intCast(@min(volume >> 2, 0x3F));
        try self.inner.setVolume(gain);
    }
};

/// No-op PA switch — BK7258 onboard DAC handles this internally
pub const PaSwitchDriver = struct {
    pub fn init(_: anytype) !PaSwitchDriver {
        return .{};
    }

    pub fn deinit(_: *PaSwitchDriver) void {}

    pub fn on(_: *PaSwitchDriver) !void {
        // No external PA to enable
    }

    pub fn off(_: *PaSwitchDriver) !void {
        // No external PA to disable
    }
};

/// No-op RTC — BK7258 uses AON RTC internally
pub const RtcDriver = struct {
    pub fn init() !RtcDriver {
        return .{};
    }

    pub fn deinit(_: *RtcDriver) void {}
};
