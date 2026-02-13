//! BK7258 Microphone Binding — DMA-based audio ADC
//!
//! Uses ADC DMA to capture audio at precise hardware-timed intervals.
//! ADC runs in LR mode (DMA requirement), L channel extracted in read().
//! Blocks on DMA ISR semaphore — each read() returns exactly one frame.

extern fn bk_zig_mic_init(sample_rate: c_uint, channels: u8, dig_gain: u8, ana_gain: u8) c_int;
extern fn bk_zig_mic_deinit() void;
extern fn bk_zig_mic_read(buffer: [*]i16, max_samples: c_uint) c_int;

pub const Mic = struct {
    initialized: bool = false,

    /// Init mic with digital gain (0x00-0x3F, 0x2d=0dB) and analog gain (0x00-0x3F)
    pub fn init(sample_rate: u32, channels: u8, dig_gain: u8, ana_gain: u8) !Mic {
        if (bk_zig_mic_init(@intCast(sample_rate), channels, dig_gain, ana_gain) != 0)
            return error.MicInitFailed;
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Mic) void {
        if (self.initialized) {
            bk_zig_mic_deinit();
            self.initialized = false;
        }
    }

    /// Read one frame of PCM samples from microphone (L channel).
    /// Blocks until DMA delivers a frame (~20ms at 8kHz).
    pub fn read(self: *Mic, buffer: []i16) !usize {
        if (!self.initialized) return error.NotInitialized;
        const ret = bk_zig_mic_read(buffer.ptr, @intCast(buffer.len));
        if (ret < 0) return error.ReadFailed;
        return @intCast(ret);
    }
};
