//! BK7258 Speaker — DMA-based DAC output
//!
//! Uses DAC DMA to play audio from ring buffer at precise hardware timing.
//! Supports PA control via GPIO 0. Pre-fills 1 frame silence at init.
//!
//! Flow: write() → Ring Buffer → DMA → DAC FIFO → Analog Out → PA → Speaker

extern fn bk_zig_speaker_init(sample_rate: u32, channels: u8, bits: u8, dig_gain: u8) i32;
extern fn bk_zig_speaker_deinit() void;
extern fn bk_zig_speaker_write(data: [*]const i16, samples: u32) i32;
extern fn bk_zig_speaker_set_volume(gain: u8) i32;

pub const Speaker = struct {
    initialized: bool = false,

    pub fn init(sample_rate: u32, channels: u8, bits: u8, dig_gain: u8) !Speaker {
        const ret = bk_zig_speaker_init(sample_rate, channels, bits, dig_gain);
        if (ret != 0) return error.SpeakerInitFailed;
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Speaker) void {
        if (self.initialized) {
            bk_zig_speaker_deinit();
            self.initialized = false;
        }
    }

    /// Write PCM samples to speaker. DMA handles playback timing.
    pub fn write(_: *Speaker, buffer: []const i16) !usize {
        const ret = bk_zig_speaker_write(buffer.ptr, @intCast(buffer.len));
        if (ret < 0) return error.SpeakerWriteFailed;
        return @intCast(ret);
    }
};

/// Set digital gain (module-level, no instance needed).
/// Range: 0x00~0x3F (-45dB to +18dB), 0x2D = 0dB.
pub fn setVolume(gain: u8) void {
    _ = bk_zig_speaker_set_volume(gain);
}
