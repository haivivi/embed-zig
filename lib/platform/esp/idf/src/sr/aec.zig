//! AEC (Acoustic Echo Cancellation) Module
//!
//! Provides acoustic echo cancellation using ESP-SR's esp_afe_aec library.
//! This module wraps the C helper functions for idiomatic Zig usage.
//!
//! ## Usage
//!
//! ```zig
//! const sr = @import("esp").sr;
//!
//! // Initialize AEC with MR format (Mic + Reference)
//! var aec = try sr.Aec.init(.{
//!     .input_format = .mr,
//!     .filter_length = 4,
//! });
//! defer aec.deinit();
//!
//! // Process audio frames
//! var input: [512]i16 = undefined;  // MIC + REF interleaved
//! var output: [256]i16 = undefined; // Clean audio
//! const samples = try aec.process(&input, &output);
//! ```

const std = @import("std");
const heap = @import("../heap.zig");

// ============================================================================
// C Helper Function Declarations
// ============================================================================

const AecHandle = opaque {};

extern fn aec_helper_create(
    input_format: [*:0]const u8,
    filter_length: c_int,
    aec_type: c_int,
    mode: c_int,
) ?*AecHandle;

extern fn aec_helper_process(
    handle: *AecHandle,
    indata: [*]const i16,
    outdata: [*]i16,
) c_int;

extern fn aec_helper_get_chunksize(handle: *AecHandle) c_int;
extern fn aec_helper_get_total_channels(handle: *AecHandle) c_int;
extern fn aec_helper_destroy(handle: *AecHandle) void;
extern fn aec_helper_alloc_buffer(samples: c_int) ?[*]i16;
extern fn aec_helper_free_buffer(buf: ?[*]i16) void;

// ============================================================================
// Public Types
// ============================================================================

/// AEC input format - determines how audio channels are arranged
pub const InputFormat = enum {
    /// Microphone + Reference (2 channels)
    /// Input: [MIC0, REF0, MIC1, REF1, ...]
    mr,

    /// Reference + Microphone (2 channels)
    /// Input: [REF0, MIC0, REF1, MIC1, ...]
    rm,

    /// Reference + Microphone + Null + Microphone (4 channels, Korvo-2 V3)
    rmnm,

    pub fn toString(self: InputFormat) [*:0]const u8 {
        return switch (self) {
            .mr => "MR",
            .rm => "RM",
            .rmnm => "RMNM",
        };
    }
};

/// AFE (Audio Front End) type
pub const AfeType = enum(c_int) {
    /// Speech Recognition mode
    sr = 0,
    /// Voice Communication mode (recommended for AEC)
    vc = 1,
    /// Voice Communication 8kHz mode
    vc_8k = 2,
};

/// AFE processing mode
pub const AfeMode = enum(c_int) {
    /// Low cost mode - less CPU usage
    low_cost = 0,
    /// High performance mode - better quality
    high_perf = 1,
};

/// AEC configuration
pub const Config = struct {
    /// Input format (channel arrangement)
    input_format: InputFormat = .mr,

    /// AEC filter length (recommended: 4 for ESP32-S3)
    filter_length: u8 = 4,

    /// AFE type
    afe_type: AfeType = .vc,

    /// AFE mode
    afe_mode: AfeMode = .low_cost,
};

/// AEC processing errors
pub const Error = error{
    /// Failed to create AEC handle
    CreateFailed,
    /// AEC processing failed
    ProcessFailed,
    /// Invalid handle (null)
    InvalidHandle,
    /// Buffer allocation failed
    OutOfMemory,
};

// ============================================================================
// AEC Struct
// ============================================================================

/// Acoustic Echo Cancellation processor
///
/// Removes echo from microphone input using a reference signal (typically
/// from the speaker output). This enables full-duplex audio communication.
pub const Aec = struct {
    const Self = @This();

    /// Opaque handle to the C AEC instance
    handle: *AecHandle,

    /// Number of samples per frame (chunk size)
    frame_size: usize,

    /// Total number of input channels
    total_channels: usize,

    /// Input format used
    input_format: InputFormat,

    /// Aligned output buffer (AEC requires 16-byte alignment)
    output_buffer: ?[*]i16 = null,

    /// Initialize AEC with the given configuration
    ///
    /// Returns an initialized AEC instance ready for processing.
    /// The frame size (chunk size) is determined by the AEC library.
    pub fn init(config: Config) Error!Self {
        const handle = aec_helper_create(
            config.input_format.toString(),
            @intCast(config.filter_length),
            @intFromEnum(config.afe_type),
            @intFromEnum(config.afe_mode),
        ) orelse return Error.CreateFailed;

        const frame_size: usize = @intCast(aec_helper_get_chunksize(handle));
        const total_channels: usize = @intCast(aec_helper_get_total_channels(handle));

        // Allocate aligned output buffer
        const output_buffer = aec_helper_alloc_buffer(@intCast(frame_size));
        if (output_buffer == null) {
            aec_helper_destroy(handle);
            return Error.OutOfMemory;
        }

        return Self{
            .handle = handle,
            .frame_size = frame_size,
            .total_channels = total_channels,
            .input_format = config.input_format,
            .output_buffer = output_buffer,
        };
    }

    /// Deinitialize AEC and free resources
    pub fn deinit(self: *Self) void {
        if (self.output_buffer) |buf| {
            aec_helper_free_buffer(buf);
            self.output_buffer = null;
        }
        aec_helper_destroy(self.handle);
    }

    /// Process one frame of audio through AEC
    ///
    /// Input should be interleaved multi-channel audio in the format
    /// specified during initialization. The input size should be
    /// `frame_size * total_channels` samples.
    ///
    /// Returns the number of output samples (typically equals frame_size).
    pub fn process(self: *Self, input: []const i16, output: []i16) Error!usize {
        const out_buf = self.output_buffer orelse return Error.OutOfMemory;

        const ret = aec_helper_process(
            self.handle,
            input.ptr,
            out_buf,
        );

        if (ret < 0) {
            return Error.ProcessFailed;
        }

        const samples: usize = @intCast(ret);
        const copy_len = @min(samples, output.len);

        // Copy from aligned buffer to output
        @memcpy(output[0..copy_len], out_buf[0..copy_len]);

        return samples;
    }

    /// Process audio using internal buffer (for use with raw pointers)
    ///
    /// This is a lower-level API that returns a pointer to the internal
    /// aligned output buffer. Useful when working with C APIs or DMA.
    pub fn processRaw(self: *Self, input: [*]const i16) Error![*]i16 {
        const out_buf = self.output_buffer orelse return Error.OutOfMemory;

        const ret = aec_helper_process(
            self.handle,
            input,
            out_buf,
        );

        if (ret < 0) {
            return Error.ProcessFailed;
        }

        return out_buf;
    }

    /// Get the frame size (samples per channel per frame)
    ///
    /// This is the number of samples that should be provided per channel
    /// in each call to process(). Typically 256 for 16ms @ 16kHz.
    pub fn getFrameSize(self: *const Self) usize {
        return self.frame_size;
    }

    /// Get the total number of input channels
    ///
    /// For "MR" format this is 2 (mic + ref).
    /// For "RMNM" format this is 4.
    pub fn getTotalChannels(self: *const Self) usize {
        return self.total_channels;
    }

    /// Get the required input buffer size in samples
    ///
    /// This is frame_size * total_channels.
    pub fn getInputSize(self: *const Self) usize {
        return self.frame_size * self.total_channels;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "InputFormat.toString" {
    try std.testing.expectEqualStrings("MR", std.mem.span(InputFormat.mr.toString()));
    try std.testing.expectEqualStrings("RM", std.mem.span(InputFormat.rm.toString()));
    try std.testing.expectEqualStrings("RMNM", std.mem.span(InputFormat.rmnm.toString()));
}

test "Config defaults" {
    const config = Config{};
    try std.testing.expectEqual(InputFormat.mr, config.input_format);
    try std.testing.expectEqual(@as(u8, 4), config.filter_length);
    try std.testing.expectEqual(AfeType.vc, config.afe_type);
    try std.testing.expectEqual(AfeMode.low_cost, config.afe_mode);
}
