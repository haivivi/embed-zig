//! SpeexDSP Zig Bindings
//!
//! Provides Zig-friendly wrappers around the SpeexDSP C library:
//! - AEC (Acoustic Echo Cancellation) via speex_echo.h
//! - Preprocessor (Noise Suppression + AGC) via speex_preprocess.h
//! - Resampler via speex_resampler.h
//! - Custom memory allocation via Zig Allocator (no libc malloc dependency)
//!
//! ## Memory Management
//!
//! SpeexDSP's internal malloc/realloc/free are overridden (OVERRIDE_SPEEX_ALLOC
//! in config.h). All allocations go through a Zig `std.mem.Allocator` that must
//! be set before calling init/deinit/setRate via `setAllocator()`.
//!
//! Each allocation prepends a header storing the total byte length, so that
//! `speex_free(ptr)` can reconstruct the original slice for `Allocator.free()`.
//!
//! **Thread safety**: `setAllocator` is not thread-safe. init/deinit must not
//! be called concurrently. `processInterleaved` does not allocate and is safe
//! to call from any thread once the resampler is initialized.
//!
//! ## Usage
//!
//! ```zig
//! const speexdsp = @import("speexdsp");
//!
//! speexdsp.setAllocator(allocator);
//! var rs = try speexdsp.Resampler.init(1, 16000, 48000, 3);
//! // processInterleaved does not allocate — safe without setAllocator
//! speexdsp.setAllocator(allocator);
//! rs.deinit();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("speex/speex_echo.h");
    @cInclude("speex/speex_preprocess.h");
    @cInclude("speex/speex_resampler.h");
});

// ============================================================================
// Allocator bridge — Zig Allocator ↔ SpeexDSP speex_alloc/realloc/free
// ============================================================================

/// Global allocator for SpeexDSP C callbacks.
/// Must be set via `setAllocator()` before any SpeexDSP init/destroy/setRate.
var global_allocator: ?Allocator = null;

/// Set the allocator used by SpeexDSP memory operations.
/// Call before init(), deinit(), or setRate().
pub fn setAllocator(a: Allocator) void {
    global_allocator = a;
}

/// Clear the global allocator. Optional — call after init/deinit to prevent
/// accidental use from unrelated code paths.
pub fn clearAllocator() void {
    global_allocator = null;
}

const AllocHeader = extern struct {
    total_len: usize,
};

const header_size = @sizeOf(AllocHeader);
const header_alignment: std.mem.Alignment = @enumFromInt(std.math.log2_int(usize, @alignOf(AllocHeader)));

/// speex_alloc replacement — calloc(size, 1) equivalent via Zig Allocator.
export fn speex_alloc(size: c_int) ?*anyopaque {
    const a = global_allocator orelse return null;
    const data_len: usize = if (size > 0) @intCast(size) else return null;
    const total = header_size + data_len;

    const buf = a.rawAlloc(total, header_alignment, @returnAddress()) orelse return null;

    @memset(buf[0..total], 0);

    const header: *AllocHeader = @ptrCast(@alignCast(buf));
    header.total_len = total;
    return buf + header_size;
}

/// speex_realloc replacement via Zig Allocator.
export fn speex_realloc(ptr: ?*anyopaque, size: c_int) ?*anyopaque {
    if (ptr == null) return speex_alloc(size);

    const a = global_allocator orelse return null;
    const new_data_len: usize = if (size > 0) @intCast(size) else {
        speex_free(ptr);
        return null;
    };

    const raw: [*]u8 = @ptrCast(ptr.?);
    const base = raw - header_size;
    const header: *const AllocHeader = @ptrCast(@alignCast(base));
    const old_total = header.total_len;
    const old_data_len = old_total - header_size;

    const new_total = header_size + new_data_len;
    const new_buf = a.rawAlloc(new_total, header_alignment, @returnAddress()) orelse return null;

    const copy_len = @min(old_data_len, new_data_len);
    @memcpy(new_buf[header_size..][0..copy_len], raw[0..copy_len]);

    if (new_data_len > old_data_len) {
        @memset(new_buf[header_size + old_data_len ..][0 .. new_data_len - old_data_len], 0);
    }

    const new_header: *AllocHeader = @ptrCast(@alignCast(new_buf));
    new_header.total_len = new_total;

    a.rawFree(base[0..old_total], header_alignment, @returnAddress());

    return new_buf + header_size;
}

/// speex_free replacement via Zig Allocator.
export fn speex_free(ptr: ?*anyopaque) void {
    if (ptr == null) return;
    const a = global_allocator orelse return;

    const raw: [*]u8 = @ptrCast(ptr.?);
    const base = raw - header_size;
    const header: *const AllocHeader = @ptrCast(@alignCast(base));
    const total = header.total_len;

    a.rawFree(base[0..total], header_alignment, @returnAddress());
}

// ============================================================================
// Echo Cancellation (AEC)
// ============================================================================

pub const EchoState = struct {
    handle: *c.SpeexEchoState,

    pub fn init(frame_size: c_int, filter_length: c_int) !EchoState {
        const handle = c.speex_echo_state_init(frame_size, filter_length);
        if (handle == null) return error.SpeexInitFailed;
        return .{ .handle = handle.? };
    }

    pub fn deinit(self: *EchoState) void {
        c.speex_echo_state_destroy(self.handle);
    }

    pub fn cancellation(self: *EchoState, mic: [*]const i16, ref: [*]const i16, out: [*]i16) void {
        c.speex_echo_cancellation(self.handle, mic, ref, out);
    }

    pub fn playback(self: *EchoState, play: [*]const i16) void {
        c.speex_echo_playback(self.handle, play);
    }

    pub fn capture(self: *EchoState, mic: [*]const i16, out: [*]i16) void {
        c.speex_echo_capture(self.handle, mic, out);
    }

    pub fn reset(self: *EchoState) void {
        c.speex_echo_state_reset(self.handle);
    }

    pub fn setSampleRate(self: *EchoState, rate: i32) void {
        var r = rate;
        _ = c.speex_echo_ctl(self.handle, c.SPEEX_ECHO_SET_SAMPLING_RATE, &r);
    }
};

// ============================================================================
// Preprocessor (Noise Suppression, AGC, VAD)
// ============================================================================

pub const Preprocess = struct {
    handle: *c.SpeexPreprocessState,

    pub fn init(frame_size: c_int, sample_rate: c_int) !Preprocess {
        const handle = c.speex_preprocess_state_init(frame_size, sample_rate);
        if (handle == null) return error.SpeexInitFailed;
        return .{ .handle = handle.? };
    }

    pub fn deinit(self: *Preprocess) void {
        c.speex_preprocess_state_destroy(self.handle);
    }

    pub fn run(self: *Preprocess, frame: [*]i16) bool {
        return c.speex_preprocess_run(self.handle, frame) != 0;
    }

    pub fn setEchoState(self: *Preprocess, echo: *EchoState) void {
        _ = c.speex_preprocess_ctl(self.handle, c.SPEEX_PREPROCESS_SET_ECHO_STATE, @ptrCast(echo.handle));
    }

    pub fn setDenoise(self: *Preprocess, db: i32) void {
        var val = db;
        _ = c.speex_preprocess_ctl(self.handle, c.SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &val);
    }

    pub fn enableDenoise(self: *Preprocess, enable: bool) void {
        var val: c_int = if (enable) 1 else 0;
        _ = c.speex_preprocess_ctl(self.handle, c.SPEEX_PREPROCESS_SET_DENOISE, &val);
    }

    pub fn enableAgc(self: *Preprocess, enable: bool) void {
        var val: c_int = if (enable) 1 else 0;
        _ = c.speex_preprocess_ctl(self.handle, c.SPEEX_PREPROCESS_SET_AGC, &val);
    }

    pub fn enableVad(self: *Preprocess, enable: bool) void {
        var val: c_int = if (enable) 1 else 0;
        _ = c.speex_preprocess_ctl(self.handle, c.SPEEX_PREPROCESS_SET_VAD, &val);
    }
};

// ============================================================================
// Resampler
// ============================================================================

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
