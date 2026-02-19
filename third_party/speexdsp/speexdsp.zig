//! SpeexDSP Zig Bindings
//!
//! Provides Zig-friendly wrappers around the SpeexDSP C library:
//! - Resampler via speex_resampler.h
//!
//! ## Usage
//!
//! ```zig
//! const speexdsp = @import("speexdsp");
//!
//! var rs = try speexdsp.Resampler.init(1, 16000, 48000, 3);
//! defer rs.deinit();
//!
//! var in_len: u32 = 160;
//! var out_len: u32 = 480;
//! try rs.processInterleaved(in_buf.ptr, &in_len, out_buf.ptr, &out_len);
//! ```

pub const c = @cImport({
    @cInclude("speex/speex_resampler.h");
});

pub const Resampler = struct {
    handle: *c.SpeexResamplerState,

    pub fn init(channels: u32, in_rate: u32, out_rate: u32, quality: c_int) !Resampler {
        var err: c_int = 0;
        const handle = c.speex_resampler_init(channels, in_rate, out_rate, quality, &err);
        if (handle == null or err != 0) return error.SpeexInitFailed;
        return .{ .handle = handle.? };
    }

    pub fn deinit(self: *Resampler) void {
        c.speex_resampler_destroy(self.handle);
    }

    pub fn processInterleaved(
        self: *Resampler,
        in_buf: [*]const i16,
        in_len: *u32,
        out_buf: [*]i16,
        out_len: *u32,
    ) !void {
        const err = c.speex_resampler_process_interleaved_int(
            self.handle,
            in_buf,
            in_len,
            out_buf,
            out_len,
        );
        if (err != 0) return error.SpeexResampleFailed;
    }

    pub fn setRate(self: *Resampler, in_rate: u32, out_rate: u32) !void {
        const err = c.speex_resampler_set_rate(self.handle, in_rate, out_rate);
        if (err != 0) return error.SpeexResampleFailed;
    }

    pub fn reset(self: *Resampler) void {
        _ = c.speex_resampler_reset_mem(self.handle);
    }
};
