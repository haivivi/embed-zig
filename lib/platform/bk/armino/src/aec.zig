//! BK7258 AEC (Acoustic Echo Cancellation) Binding
//!
//! Wraps Armino's standalone AEC library (libaec.a).
//! API: aec_init → aec_proc (per frame) → free.
//!
//! Frame size: 160 samples @ 8kHz, 320 samples @ 16kHz (always 20ms).

const std = @import("std");

// Opaque AEC context
const AECContext = opaque {};

// C API (from modules/aec.h, implemented in libaec.a)
extern fn aec_size(delay: u32) u32;
extern fn aec_init(ctx: *AECContext, fs: i16) void;
extern fn aec_ctrl(ctx: *AECContext, cmd: u32, arg: u32) void;
extern fn aec_proc(ctx: *AECContext, rin: [*]i16, sin: [*]i16, out: [*]i16) void;

// From os/mem.h
extern fn bk_zig_psram_malloc(size: u32) ?[*]u8;
extern fn bk_zig_free(ptr: [*]u8) void;

// AEC control commands (enum AEC_CTRL_CMD, sequential from 0)
const CMD_SET_MIC_DELAY: u32 = 2; // AEC_CTRL_CMD_SET_MIC_DELAY
const CMD_SET_EC_DEPTH: u32 = 4; // AEC_CTRL_CMD_SET_EC_DEPTH
const CMD_SET_NS_LEVEL: u32 = 6; // AEC_CTRL_CMD_SET_NS_LEVEL
const CMD_SET_DRC: u32 = 8; // AEC_CTRL_CMD_SET_DRC
const CMD_SET_FLAGS: u32 = 10; // AEC_CTRL_CMD_SET_FLAGS
const CMD_GET_RX_BUF: u32 = 22; // AEC_CTRL_CMD_GET_RX_BUF (ref/speaker)
const CMD_GET_TX_BUF: u32 = 23; // AEC_CTRL_CMD_GET_TX_BUF (mic)
const CMD_GET_OUT_BUF: u32 = 24; // AEC_CTRL_CMD_GET_OUT_BUF (output)
const CMD_GET_FRAME_SAMPLE: u32 = 25; // AEC_CTRL_CMD_GET_FRAME_SAMPLE

pub const Aec = struct {
    ctx: *AECContext,
    frame_samples: u32,
    ref_buf: [*]i16, // internal reusable buffer for reference (speaker) data
    mic_buf: [*]i16, // internal reusable buffer for mic data
    out_buf: [*]i16, // internal reusable buffer for output

    /// Initialize AEC.
    /// delay: max mic delay in samples (suggest 1000).
    /// sample_rate: 8000 or 16000.
    pub fn init(delay: u32, sample_rate: u16) !Aec {
        const ctx_size = aec_size(delay);
        const ptr = bk_zig_psram_malloc(ctx_size) orelse return error.OutOfMemory;
        const ctx: *AECContext = @ptrCast(@alignCast(ptr));

        aec_init(ctx, @intCast(sample_rate));

        // Get frame size
        var frame_samples: u32 = 0;
        aec_ctrl(ctx, CMD_GET_FRAME_SAMPLE, @intFromPtr(&frame_samples));

        // Get internal buffer pointers (reusable, no need to malloc)
        var ref_ptr: usize = 0;
        var mic_ptr: usize = 0;
        var out_ptr: usize = 0;
        aec_ctrl(ctx, CMD_GET_RX_BUF, @intFromPtr(&ref_ptr));
        aec_ctrl(ctx, CMD_GET_TX_BUF, @intFromPtr(&mic_ptr));
        aec_ctrl(ctx, CMD_GET_OUT_BUF, @intFromPtr(&out_ptr));

        // Apply default tuning parameters
        aec_ctrl(ctx, CMD_SET_FLAGS, 0x1f); // all modules on
        aec_ctrl(ctx, CMD_SET_MIC_DELAY, 10);
        aec_ctrl(ctx, CMD_SET_EC_DEPTH, 5);
        aec_ctrl(ctx, CMD_SET_NS_LEVEL, 2);
        aec_ctrl(ctx, CMD_SET_DRC, 0x15);

        return .{
            .ctx = ctx,
            .frame_samples = frame_samples,
            .ref_buf = @ptrFromInt(ref_ptr),
            .mic_buf = @ptrFromInt(mic_ptr),
            .out_buf = @ptrFromInt(out_ptr),
        };
    }

    pub fn deinit(self: *Aec) void {
        bk_zig_free(@ptrCast(self.ctx));
    }

    /// Process one frame of AEC.
    /// ref: speaker reference signal (frame_samples samples)
    /// mic: raw microphone signal (frame_samples samples)
    /// out: echo-cancelled output (frame_samples samples)
    pub fn process(self: *Aec, ref: []const i16, mic: []const i16, out: []i16) void {
        const n = self.frame_samples;
        // Copy input data to internal buffers
        @memcpy(self.ref_buf[0..n], ref[0..n]);
        @memcpy(self.mic_buf[0..n], mic[0..n]);
        // Run AEC
        aec_proc(self.ctx, self.ref_buf, self.mic_buf, self.out_buf);
        // Copy output
        @memcpy(out[0..n], self.out_buf[0..n]);
    }

    /// Process using internal buffers directly (zero-copy for ref/mic).
    /// Caller writes ref data to getRefBuf() and mic data to getMicBuf()
    /// before calling, then reads result from getOutBuf().
    pub fn processInPlace(self: *Aec) void {
        aec_proc(self.ctx, self.ref_buf, self.mic_buf, self.out_buf);
    }

    pub fn getFrameSamples(self: *const Aec) u32 {
        return self.frame_samples;
    }

    pub fn getRefBuf(self: *Aec) []i16 {
        return self.ref_buf[0..self.frame_samples];
    }

    pub fn getMicBuf(self: *Aec) []i16 {
        return self.mic_buf[0..self.frame_samples];
    }

    pub fn getOutBuf(self: *Aec) []i16 {
        return self.out_buf[0..self.frame_samples];
    }
};
