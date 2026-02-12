//! BK7258 Microphone Binding — Direct audio ADC + DMA

extern fn bk_zig_mic_init(sample_rate: c_uint, channels: u8, gain: u8) c_int;
extern fn bk_zig_mic_deinit() void;
extern fn bk_zig_mic_read(buffer: [*]i16, max_samples: c_uint) c_int;

pub const Mic = struct {
    initialized: bool = false,

    pub fn init(sample_rate: u32, channels: u8, gain: u8) !Mic {
        if (bk_zig_mic_init(@intCast(sample_rate), channels, gain) != 0)
            return error.MicInitFailed;
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Mic) void {
        if (self.initialized) {
            bk_zig_mic_deinit();
            self.initialized = false;
        }
    }

    /// Read PCM samples from microphone. Blocks until data available.
    /// Returns slice of samples read.
    pub fn read(self: *Mic, buffer: []i16) !usize {
        if (!self.initialized) return error.NotInitialized;
        const ret = bk_zig_mic_read(buffer.ptr, @intCast(buffer.len));
        if (ret < 0) return error.ReadFailed;
        return @intCast(ret);
    }
};
