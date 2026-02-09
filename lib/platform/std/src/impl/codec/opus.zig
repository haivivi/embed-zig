//! Codec Implementation — Zig std platform
//!
//! Wraps lib/pkg/audio opus bindings to satisfy trait.codec contracts.
//! Uses a caller-provided allocator for encoder/decoder state.
//!
//! Usage:
//!   const codec_impl = @import("std_impl").codec;
//!   var enc = try codec_impl.OpusEncoder.init(allocator, 16000, 1, .voip);
//!   defer enc.deinit(allocator);
//!   const encoded = try enc.encode(&pcm, 320, &out);

const std = @import("std");
const opus = @import("opus");

/// Opus encoder satisfying trait.codec.Encoder
pub const OpusEncoder = struct {
    inner: opus.Encoder,
    frame_ms: u32,
    alloc: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        channels: u8,
        application: opus.Application,
        frame_ms: u32,
    ) !Self {
        const inner = try opus.Encoder.init(allocator, sample_rate, channels, application);
        return .{ .inner = inner, .frame_ms = frame_ms, .alloc = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.inner.deinit(self.alloc);
        self.* = undefined;
    }

    /// trait.codec.Encoder: encode PCM to opus
    pub fn encode(self: *Self, pcm: []const i16, frame_size: u32, out: []u8) ![]const u8 {
        return self.inner.encode(pcm, frame_size, out);
    }

    /// trait.codec.Encoder: samples per frame
    pub fn frameSize(self: *const Self) u32 {
        return self.inner.frameSizeForMs(self.frame_ms);
    }

    // ----- opus-specific ctl passthrough -----

    pub fn setBitrate(self: *Self, bitrate: u32) !void {
        return self.inner.setBitrate(bitrate);
    }
    pub fn setComplexity(self: *Self, complexity: u4) !void {
        return self.inner.setComplexity(complexity);
    }
    pub fn setSignal(self: *Self, signal: opus.Signal) !void {
        return self.inner.setSignal(signal);
    }
};

/// Opus decoder satisfying trait.codec.Decoder
pub const OpusDecoder = struct {
    inner: opus.Decoder,
    frame_ms: u32,
    alloc: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        channels: u8,
        frame_ms: u32,
    ) !Self {
        const inner = try opus.Decoder.init(allocator, sample_rate, channels);
        return .{ .inner = inner, .frame_ms = frame_ms, .alloc = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.inner.deinit(self.alloc);
        self.* = undefined;
    }

    /// trait.codec.Decoder: decode opus to PCM
    pub fn decode(self: *Self, data: []const u8, pcm: []i16) ![]const i16 {
        return self.inner.decode(data, pcm, false);
    }

    /// trait.codec.Decoder: samples per frame
    pub fn frameSize(self: *const Self) u32 {
        return self.inner.frameSizeForMs(self.frame_ms);
    }

    /// Packet loss concealment
    pub fn plc(self: *Self, pcm: []i16) ![]const i16 {
        return self.inner.plc(pcm);
    }
};
