//! BK7258 AEC (Acoustic Echo Cancellation) Binding
//!
//! Wraps bk_zig_aec_helper.c which wraps Armino's libaec.a.
//! C helper avoids Zig extern ABI issues with prebuilt ARM library.
//!
//! Frame size: 160 samples @ 8kHz, 320 samples @ 16kHz (always 20ms).

extern fn bk_zig_aec_init(delay: c_uint, sample_rate: u16) c_int;
extern fn bk_zig_aec_deinit() void;
extern fn bk_zig_aec_get_frame_samples() c_uint;
extern fn bk_zig_aec_process(ref: [*]const i16, mic: [*]const i16, out: [*]i16) void;

pub const Aec = struct {
    frame_samples: u32,

    /// Initialize AEC.
    /// delay: max mic delay in samples (suggest 1000).
    /// sample_rate: 8000 or 16000.
    pub fn init(delay: u32, sample_rate: u16) !Aec {
        if (bk_zig_aec_init(@intCast(delay), sample_rate) != 0)
            return error.AecInitFailed;

        const fs = bk_zig_aec_get_frame_samples();
        return .{ .frame_samples = fs };
    }

    pub fn deinit(_: *Aec) void {
        bk_zig_aec_deinit();
    }

    /// Process one frame of AEC.
    /// ref: speaker reference signal (frame_samples samples)
    /// mic: raw microphone signal (frame_samples samples)
    /// out: echo-cancelled output (frame_samples samples)
    pub fn process(_: *Aec, ref: []const i16, mic: []const i16, out: []i16) void {
        bk_zig_aec_process(ref.ptr, mic.ptr, out.ptr);
    }

    pub fn getFrameSamples(self: *const Aec) u32 {
        return self.frame_samples;
    }
};
