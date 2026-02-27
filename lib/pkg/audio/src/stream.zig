//! Audio Stream — generic encode/decode loops
//!
//! Codec-agnostic pipeline stages. Each loop reads from a Source,
//! transforms via a codec (satisfying trait.codec), and writes to a Sink.
//! Designed to run as a task (via WaitGroup.go or Runtime.spawn).
//!
//! ## Source contract
//!   fn read(*Src, buf: []i16) ?usize    — for encodeLoop (PCM producer)
//!   fn read(*Src, buf: []u8) ?[]const u8 — for decodeLoop (packet producer)
//!
//! ## Sink contract
//!   fn write(*Sink, data: []const u8) void  — for encodeLoop (packet consumer)
//!   fn write(*Sink, pcm: []const i16) void  — for decodeLoop (PCM consumer)
//!
//! ## Usage
//!
//! ```zig
//! const stream = audio.stream;
//!
//! // Launch as task:
//! // mic → encode → channel
//! stream.encodeLoop(&mic_src, &encoder, &channel_sink);
//!
//! // channel → decode → speaker
//! stream.decodeLoop(&channel_src, &decoder, &speaker_sink);
//! ```

const trait = @import("trait");

/// Encode loop: read PCM from Src → encode via Enc → write to Sink.
///
/// Accumulates PCM samples until a full frame is available, then encodes.
/// Runs until `src.read()` returns null (source exhausted / cancelled).
///
/// Enc must satisfy trait.codec.Encoder (encode + frameSize).
/// Buffers are stack-allocated from comptime frame_size.
pub fn encodeLoop(
    comptime Src: type,
    comptime Enc: type,
    comptime Sink: type,
    src: *Src,
    enc: *Enc,
    sink: *Sink,
) void {
    // Validate Enc satisfies codec.Encoder trait
    comptime {
        _ = trait.codec.Encoder(Enc);
    }

    const frame_size = enc.frameSize();
    const max_opus: usize = 1275; // max opus packet per RFC 6716

    var accum: [7680]i16 = undefined; // max 120ms @ 48kHz stereo
    var opus_buf: [max_opus]u8 = undefined;
    var accum_n: usize = 0;

    while (true) {
        const remaining = frame_size - accum_n;
        const n = src.read(accum[accum_n..][0..remaining]) orelse break;
        accum_n += n;

        if (accum_n < frame_size) continue;

        // Full frame ready — encode
        const encoded = enc.encode(accum[0..frame_size], @intCast(frame_size), &opus_buf) catch continue;
        accum_n = 0;

        sink.write(encoded);
    }
}

/// Decode loop: read packets from Src → decode via Dec → write to Sink.
///
/// Runs until `src.read()` returns null (source exhausted / cancelled).
///
/// Dec must satisfy trait.codec.Decoder (decode + frameSize).
pub fn decodeLoop(
    comptime Src: type,
    comptime Dec: type,
    comptime Sink: type,
    src: *Src,
    dec: *Dec,
    sink: *Sink,
) void {
    // Validate Dec satisfies codec.Decoder trait
    comptime {
        _ = trait.codec.Decoder(Dec);
    }

    const frame_size = dec.frameSize();
    var pcm_buf: [7680]i16 = undefined; // max 120ms @ 48kHz stereo

    while (true) {
        const packet = src.read() orelse break;

        const decoded = dec.decode(packet, pcm_buf[0..frame_size]) catch continue;

        if (decoded.len > 0) {
            sink.write(decoded);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");
const testing = std.testing;

const IdentityEncoder = struct {
    frame_sz: u32 = 160,

    pub fn encode(self: *IdentityEncoder, pcm: []const i16, frame_size: u32, out: []u8) ![]const u8 {
        _ = self;
        const bytes = std.mem.sliceAsBytes(pcm[0..frame_size]);
        @memcpy(out[0..bytes.len], bytes);
        return out[0..bytes.len];
    }

    pub fn frameSize(self: *const IdentityEncoder) u32 {
        return self.frame_sz;
    }
};

const IdentityDecoder = struct {
    frame_sz: u32 = 160,

    pub fn decode(self: *IdentityDecoder, data: []const u8, pcm: []i16) ![]const i16 {
        _ = self;
        const aligned: []align(@alignOf(i16)) const u8 = @alignCast(data);
        const src = std.mem.bytesAsSlice(i16, aligned);
        const n = @min(src.len, pcm.len);
        @memcpy(pcm[0..n], src[0..n]);
        return pcm[0..n];
    }

    pub fn frameSize(self: *const IdentityDecoder) u32 {
        return self.frame_sz;
    }
};

const PcmSource = struct {
    data: []const i16,
    pos: usize = 0,

    pub fn read(self: *PcmSource, buf: []i16) ?usize {
        if (self.pos >= self.data.len) return null;
        const remaining = self.data.len - self.pos;
        const n = @min(buf.len, remaining);
        @memcpy(buf[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

const PacketSource = struct {
    packets: []const []const u8,
    idx: usize = 0,

    pub fn read(self: *PacketSource) ?[]const u8 {
        if (self.idx >= self.packets.len) return null;
        const pkt = self.packets[self.idx];
        self.idx += 1;
        return pkt;
    }
};

const PacketSink = struct {
    count: usize = 0,
    total_bytes: usize = 0,

    pub fn write(self: *PacketSink, data: []const u8) void {
        self.count += 1;
        self.total_bytes += data.len;
    }
};

const PcmSink = struct {
    count: usize = 0,
    total_samples: usize = 0,

    pub fn write(self: *PcmSink, pcm: []const i16) void {
        self.count += 1;
        self.total_samples += pcm.len;
    }
};

test "E2E-8: encodeLoop normal flow" {
    var pcm_data: [480]i16 = undefined;
    for (&pcm_data, 0..) |*s, i| s.* = @intCast(@rem(@as(i32, @intCast(i)), 100));

    var src = PcmSource{ .data = &pcm_data };
    var enc = IdentityEncoder{ .frame_sz = 160 };
    var sink = PacketSink{};

    encodeLoop(PcmSource, IdentityEncoder, PacketSink, &src, &enc, &sink);

    // 480 samples / 160 frame_size = 3 packets
    try testing.expectEqual(@as(usize, 3), sink.count);
    try testing.expectEqual(@as(usize, 160 * 2 * 3), sink.total_bytes);
}

test "E2E-8: encodeLoop partial frame at end" {
    // 200 samples: 1 full frame (160) + 40 leftover (dropped)
    var pcm_data: [200]i16 = undefined;
    for (&pcm_data) |*s| s.* = 1000;

    var src = PcmSource{ .data = &pcm_data };
    var enc = IdentityEncoder{ .frame_sz = 160 };
    var sink = PacketSink{};

    encodeLoop(PcmSource, IdentityEncoder, PacketSink, &src, &enc, &sink);

    try testing.expectEqual(@as(usize, 1), sink.count);
}

test "E2E-8: encodeLoop empty source" {
    var src = PcmSource{ .data = &.{} };
    var enc = IdentityEncoder{};
    var sink = PacketSink{};

    encodeLoop(PcmSource, IdentityEncoder, PacketSink, &src, &enc, &sink);

    try testing.expectEqual(@as(usize, 0), sink.count);
}

test "E2E-9: decodeLoop normal flow" {
    var pcm1: [160]i16 = undefined;
    var pcm2: [160]i16 = undefined;
    for (&pcm1) |*s| s.* = 500;
    for (&pcm2) |*s| s.* = 1000;
    const pkt1 = std.mem.sliceAsBytes(&pcm1);
    const pkt2 = std.mem.sliceAsBytes(&pcm2);
    const packets = [_][]const u8{ pkt1, pkt2 };

    var src = PacketSource{ .packets = &packets };
    var dec = IdentityDecoder{ .frame_sz = 160 };
    var sink = PcmSink{};

    decodeLoop(PacketSource, IdentityDecoder, PcmSink, &src, &dec, &sink);

    try testing.expectEqual(@as(usize, 2), sink.count);
    try testing.expectEqual(@as(usize, 320), sink.total_samples);
}

test "E2E-9: decodeLoop empty source" {
    const packets = [_][]const u8{};
    var src = PacketSource{ .packets = &packets };
    var dec = IdentityDecoder{};
    var sink = PcmSink{};

    decodeLoop(PacketSource, IdentityDecoder, PcmSink, &src, &dec, &sink);

    try testing.expectEqual(@as(usize, 0), sink.count);
}
