//! Codec Implementation — BK7258 platform (FIXED_POINT, PSRAM)
//!
//! Wraps opus bindings with BK-optimized defaults:
//! - Allocates encoder/decoder state on PSRAM (BK7258 has 8MB/16MB PSRAM)
//! - complexity=0 (fastest encode on Cortex-M33)
//! - signal=voice (optimized for speech)

const std = @import("std");
const opus = @import("opus");
const armino = @import("../../../armino/src/armino.zig");

const heap = armino.heap;

/// Opus encoder for BK7258 — PSRAM allocated, complexity=0
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

/// Opus decoder for BK7258 — PSRAM allocated
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
