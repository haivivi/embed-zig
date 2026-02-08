//! Codec Implementation — ESP platform (FIXED_POINT, PSRAM)
//!
//! Wraps opus bindings with ESP-optimized defaults:
//! - Allocates encoder/decoder state on PSRAM (large, off-chip)
//! - complexity=0 (fastest encode on Xtensa)
//! - signal=voice (optimized for speech)

const std = @import("std");
const opus = @import("opus");
const idf = @import("idf");

const heap = idf.heap;

/// Opus encoder for ESP32 — PSRAM allocated, complexity=0
pub const OpusEncoder = struct {
    inner: opus.Encoder,
    frame_ms: u32,

    const Self = @This();

    pub fn init(sample_rate: u32, channels: u8, application: opus.Application, frame_ms: u32) !Self {
        var inner = try opus.Encoder.init(heap.psram, sample_rate, channels, application);
        inner.setComplexity(0) catch {};
        inner.setSignal(.voice) catch {};
        return .{ .inner = inner, .frame_ms = frame_ms };
    }

    pub fn deinit(self: *Self) void {
        self.inner.deinit(heap.psram);
        self.* = undefined;
    }

    /// trait.codec.Encoder
    pub fn encode(self: *Self, pcm: []const i16, frame_size: u32, out: []u8) ![]const u8 {
        return self.inner.encode(pcm, frame_size, out);
    }

    /// trait.codec.Encoder
    pub fn frameSize(self: *const Self) u32 {
        return self.inner.frameSizeForMs(self.frame_ms);
    }

    // opus-specific passthrough
    pub fn setBitrate(self: *Self, bitrate: u32) !void {
        return self.inner.setBitrate(bitrate);
    }
    pub fn setComplexity(self: *Self, complexity: u4) !void {
        return self.inner.setComplexity(complexity);
    }
};

/// Opus decoder for ESP32 — PSRAM allocated
pub const OpusDecoder = struct {
    inner: opus.Decoder,
    frame_ms: u32,

    const Self = @This();

    pub fn init(sample_rate: u32, channels: u8, frame_ms: u32) !Self {
        const inner = try opus.Decoder.init(heap.psram, sample_rate, channels);
        return .{ .inner = inner, .frame_ms = frame_ms };
    }

    pub fn deinit(self: *Self) void {
        self.inner.deinit(heap.psram);
        self.* = undefined;
    }

    /// trait.codec.Decoder
    pub fn decode(self: *Self, data: []const u8, pcm: []i16) ![]const i16 {
        return self.inner.decode(data, pcm, false);
    }

    /// trait.codec.Decoder
    pub fn frameSize(self: *const Self) u32 {
        return self.inner.frameSizeForMs(self.frame_ms);
    }

    pub fn plc(self: *Self, pcm: []i16) ![]const i16 {
        return self.inner.plc(pcm);
    }
};
