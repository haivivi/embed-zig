//! Zig bindings for libopus
//!
//! Opus is a versatile audio codec designed for interactive speech and audio
//! transmission over the Internet. This module provides a Zig-friendly interface.

const std = @import("std");
const c = @cImport({
    @cInclude("opus.h");
});

/// Opus error codes
pub const Error = error{
    BadArg,
    BufferTooSmall,
    InternalError,
    InvalidPacket,
    Unimplemented,
    InvalidState,
    AllocFail,
    Unknown,
};

fn checkError(code: c_int) Error!void {
    if (code < 0) {
        return switch (code) {
            c.OPUS_BAD_ARG => Error.BadArg,
            c.OPUS_BUFFER_TOO_SMALL => Error.BufferTooSmall,
            c.OPUS_INTERNAL_ERROR => Error.InternalError,
            c.OPUS_INVALID_PACKET => Error.InvalidPacket,
            c.OPUS_UNIMPLEMENTED => Error.Unimplemented,
            c.OPUS_INVALID_STATE => Error.InvalidState,
            c.OPUS_ALLOC_FAIL => Error.AllocFail,
            else => Error.Unknown,
        };
    }
}

/// Application types for encoder
pub const Application = enum(c_int) {
    /// Best for most VoIP/videoconference applications
    voip = c.OPUS_APPLICATION_VOIP,
    /// Best for broadcast/high-fidelity application
    audio = c.OPUS_APPLICATION_AUDIO,
    /// Only use when lowest-achievable latency is needed
    restricted_lowdelay = c.OPUS_APPLICATION_RESTRICTED_LOWDELAY,
};

/// Signal types
pub const Signal = enum(c_int) {
    auto = c.OPUS_AUTO,
    voice = c.OPUS_SIGNAL_VOICE,
    music = c.OPUS_SIGNAL_MUSIC,
};

/// Bandwidth types
pub const Bandwidth = enum(c_int) {
    auto = c.OPUS_AUTO,
    narrowband = c.OPUS_BANDWIDTH_NARROWBAND,
    mediumband = c.OPUS_BANDWIDTH_MEDIUMBAND,
    wideband = c.OPUS_BANDWIDTH_WIDEBAND,
    superwideband = c.OPUS_BANDWIDTH_SUPERWIDEBAND,
    fullband = c.OPUS_BANDWIDTH_FULLBAND,
};

/// Opus encoder wrapper
pub const Encoder = struct {
    handle: *c.OpusEncoder,

    const Self = @This();

    /// Create a new encoder
    ///
    /// Args:
    ///   sample_rate: Sampling rate (8000, 12000, 16000, 24000, or 48000 Hz)
    ///   channels: Number of channels (1 or 2)
    ///   application: Intended application type
    pub fn init(sample_rate: i32, channels: i32, application: Application) Error!Self {
        var err: c_int = 0;
        const handle = c.opus_encoder_create(sample_rate, channels, @intFromEnum(application), &err);
        try checkError(err);
        if (handle == null) return Error.AllocFail;
        return Self{ .handle = handle.? };
    }

    /// Destroy the encoder
    pub fn deinit(self: *Self) void {
        c.opus_encoder_destroy(self.handle);
    }

    /// Encode audio samples (16-bit PCM)
    ///
    /// Args:
    ///   pcm: Input PCM samples (interleaved if stereo)
    ///   frame_size: Number of samples per channel (2.5, 5, 10, 20, 40, 60, 80, 100, or 120 ms)
    ///   data: Output buffer for encoded data
    ///
    /// Returns: Number of bytes written to output buffer
    pub fn encode(self: *Self, pcm: []const i16, frame_size: i32, data: []u8) Error!usize {
        const ret = c.opus_encode(
            self.handle,
            pcm.ptr,
            frame_size,
            data.ptr,
            @intCast(data.len),
        );
        try checkError(ret);
        return @intCast(ret);
    }

    /// Encode float audio samples
    pub fn encodeFloat(self: *Self, pcm: []const f32, frame_size: i32, data: []u8) Error!usize {
        const ret = c.opus_encode_float(
            self.handle,
            pcm.ptr,
            frame_size,
            data.ptr,
            @intCast(data.len),
        );
        try checkError(ret);
        return @intCast(ret);
    }

    /// Set encoder bitrate (bits per second)
    pub fn setBitrate(self: *Self, bitrate: i32) Error!void {
        const ret = c.opus_encoder_ctl(self.handle, c.OPUS_SET_BITRATE_REQUEST, bitrate);
        try checkError(ret);
    }

    /// Get encoder bitrate
    pub fn getBitrate(self: *Self) Error!i32 {
        var bitrate: i32 = 0;
        const ret = c.opus_encoder_ctl(self.handle, c.OPUS_GET_BITRATE_REQUEST, &bitrate);
        try checkError(ret);
        return bitrate;
    }

    /// Set complexity (0-10, higher = better quality but slower)
    pub fn setComplexity(self: *Self, complexity: i32) Error!void {
        const ret = c.opus_encoder_ctl(self.handle, c.OPUS_SET_COMPLEXITY_REQUEST, complexity);
        try checkError(ret);
    }

    /// Set signal type hint
    pub fn setSignal(self: *Self, signal: Signal) Error!void {
        const ret = c.opus_encoder_ctl(self.handle, c.OPUS_SET_SIGNAL_REQUEST, @intFromEnum(signal));
        try checkError(ret);
    }

    /// Set bandwidth
    pub fn setBandwidth(self: *Self, bandwidth: Bandwidth) Error!void {
        const ret = c.opus_encoder_ctl(self.handle, c.OPUS_SET_BANDWIDTH_REQUEST, @intFromEnum(bandwidth));
        try checkError(ret);
    }

    /// Enable/disable VBR (variable bitrate)
    pub fn setVbr(self: *Self, enable: bool) Error!void {
        const ret = c.opus_encoder_ctl(self.handle, c.OPUS_SET_VBR_REQUEST, @as(c_int, if (enable) 1 else 0));
        try checkError(ret);
    }

    /// Enable/disable DTX (discontinuous transmission)
    pub fn setDtx(self: *Self, enable: bool) Error!void {
        const ret = c.opus_encoder_ctl(self.handle, c.OPUS_SET_DTX_REQUEST, @as(c_int, if (enable) 1 else 0));
        try checkError(ret);
    }

    /// Reset encoder state
    pub fn resetState(self: *Self) Error!void {
        const ret = c.opus_encoder_ctl(self.handle, c.OPUS_RESET_STATE);
        try checkError(ret);
    }
};

/// Opus decoder wrapper
pub const Decoder = struct {
    handle: *c.OpusDecoder,

    const Self = @This();

    /// Create a new decoder
    ///
    /// Args:
    ///   sample_rate: Sampling rate (8000, 12000, 16000, 24000, or 48000 Hz)
    ///   channels: Number of channels (1 or 2)
    pub fn init(sample_rate: i32, channels: i32) Error!Self {
        var err: c_int = 0;
        const handle = c.opus_decoder_create(sample_rate, channels, &err);
        try checkError(err);
        if (handle == null) return Error.AllocFail;
        return Self{ .handle = handle.? };
    }

    /// Destroy the decoder
    pub fn deinit(self: *Self) void {
        c.opus_decoder_destroy(self.handle);
    }

    /// Decode compressed data to PCM
    ///
    /// Args:
    ///   data: Compressed data (null for packet loss concealment)
    ///   frame_size: Max number of samples per channel to decode
    ///   pcm: Output buffer for PCM samples
    ///   fec: Whether to use forward error correction (if available)
    ///
    /// Returns: Number of decoded samples per channel
    pub fn decode(self: *Self, data: ?[]const u8, frame_size: i32, pcm: []i16, fec: bool) Error!i32 {
        const data_ptr = if (data) |d| d.ptr else null;
        const data_len: c_int = if (data) |d| @intCast(d.len) else 0;
        const ret = c.opus_decode(
            self.handle,
            data_ptr,
            data_len,
            pcm.ptr,
            frame_size,
            @intFromBool(fec),
        );
        try checkError(ret);
        return ret;
    }

    /// Decode compressed data to float PCM
    pub fn decodeFloat(self: *Self, data: ?[]const u8, frame_size: i32, pcm: []f32, fec: bool) Error!i32 {
        const data_ptr = if (data) |d| d.ptr else null;
        const data_len: c_int = if (data) |d| @intCast(d.len) else 0;
        const ret = c.opus_decode_float(
            self.handle,
            data_ptr,
            data_len,
            pcm.ptr,
            frame_size,
            @intFromBool(fec),
        );
        try checkError(ret);
        return ret;
    }

    /// Get decoder sample rate
    pub fn getSampleRate(self: *Self) Error!i32 {
        var sample_rate: i32 = 0;
        const ret = c.opus_decoder_ctl(self.handle, c.OPUS_GET_SAMPLE_RATE_REQUEST, &sample_rate);
        try checkError(ret);
        return sample_rate;
    }

    /// Reset decoder state
    pub fn resetState(self: *Self) Error!void {
        const ret = c.opus_decoder_ctl(self.handle, c.OPUS_RESET_STATE);
        try checkError(ret);
    }
};

// =============================================================================
// Utility functions
// =============================================================================

/// Get libopus version string
pub fn getVersionString() [*:0]const u8 {
    return c.opus_get_version_string();
}

/// Get human-readable error string
pub fn strerror(err: c_int) [*:0]const u8 {
    return c.opus_strerror(err);
}

/// Get the number of samples in an Opus packet
pub fn packetGetNbSamples(data: []const u8, sample_rate: i32) Error!i32 {
    const ret = c.opus_packet_get_nb_samples(data.ptr, @intCast(data.len), sample_rate);
    try checkError(ret);
    return ret;
}

/// Get the number of channels in an Opus packet
pub fn packetGetNbChannels(data: []const u8) Error!i32 {
    const ret = c.opus_packet_get_nb_channels(data.ptr);
    try checkError(ret);
    return ret;
}

/// Get the bandwidth of an Opus packet
pub fn packetGetBandwidth(data: []const u8) Error!Bandwidth {
    const ret = c.opus_packet_get_bandwidth(data.ptr);
    try checkError(ret);
    return @enumFromInt(ret);
}

/// Get the number of frames in an Opus packet
pub fn packetGetNbFrames(data: []const u8) Error!i32 {
    const ret = c.opus_packet_get_nb_frames(data.ptr, @intCast(data.len));
    try checkError(ret);
    return ret;
}

// =============================================================================
// Tests
// =============================================================================

test "version string" {
    const version = getVersionString();
    const slice = std.mem.span(version);
    try std.testing.expect(slice.len > 0);
}

test "encoder lifecycle" {
    var encoder = try Encoder.init(48000, 2, .audio);
    defer encoder.deinit();

    try encoder.setBitrate(64000);
    const bitrate = try encoder.getBitrate();
    try std.testing.expect(bitrate > 0);
}

test "decoder lifecycle" {
    var decoder = try Decoder.init(48000, 2);
    defer decoder.deinit();

    const sample_rate = try decoder.getSampleRate();
    try std.testing.expectEqual(@as(i32, 48000), sample_rate);
}
