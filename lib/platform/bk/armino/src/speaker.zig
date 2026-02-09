//! BK7258 Onboard Speaker via Armino Audio Pipeline
//!
//! Uses: audio_pipeline → raw_stream → onboard_speaker_stream → DAC
//! All complex C API calls go through bk_zig_speaker_helper.c

// C helper functions (defined in bk_zig_speaker_helper.c)
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

    /// Write PCM samples to speaker. Returns number of samples written.
    pub fn write(self: *Speaker, buffer: []const i16) !usize {
        _ = self;
        const ret = bk_zig_speaker_write(buffer.ptr, @intCast(buffer.len));
        if (ret < 0) return error.SpeakerWriteFailed;
        return @intCast(ret);
    }

    /// Set digital gain (0x00-0x3F, 0x2d = 0dB)
    pub fn setVolume(self: *Speaker, gain: u8) !void {
        _ = self;
        const ret = bk_zig_speaker_set_volume(gain);
        if (ret != 0) return error.SetVolumeFailed;
    }
};
