//! Opus Codec Wrapper — trait.codec compatible
//!
//! Wraps the raw opus Encoder/Decoder with frame_ms tracking
//! and allocator management. Cross-platform (works with both
//! opus_fixed and opus_float).
//!
//! Usage:
//!   const codec = @import("audio").opus_codec;
//!   var enc = try codec.OpusEncoder.init(allocator, 16000, 1, .voip, 20);
//!   defer enc.deinit();

const std = @import("std");
const opus = @import("opus");

pub const OpusEncoder = struct {
    inner: opus.Encoder,
    frame_ms: u32,
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8, application: opus.Application, frame_ms: u32) !OpusEncoder {
        const inner = try opus.Encoder.init(allocator, sample_rate, channels, application);
        return .{ .inner = inner, .frame_ms = frame_ms, .alloc = allocator };
    }

    pub fn deinit(self: *OpusEncoder) void {
        self.inner.deinit(self.alloc);
    }

    pub fn encode(self: *OpusEncoder, pcm: []const i16, frame_size: u32, out: []u8) ![]const u8 {
        return self.inner.encode(pcm, frame_size, out);
    }

    pub fn frameSize(self: *const OpusEncoder) u32 {
        return self.inner.frameSizeForMs(self.frame_ms);
    }
};

pub const OpusDecoder = struct {
    inner: opus.Decoder,
    frame_ms: u32,
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8, frame_ms: u32) !OpusDecoder {
        const inner = try opus.Decoder.init(allocator, sample_rate, channels);
        return .{ .inner = inner, .frame_ms = frame_ms, .alloc = allocator };
    }

    pub fn deinit(self: *OpusDecoder) void {
        self.inner.deinit(self.alloc);
    }

    pub fn decode(self: *OpusDecoder, data: []const u8, pcm: []i16) ![]const i16 {
        return self.inner.decode(data, pcm, false);
    }

    pub fn frameSize(self: *const OpusDecoder) u32 {
        return self.inner.frameSizeForMs(self.frame_ms);
    }
};
