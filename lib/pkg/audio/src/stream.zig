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
