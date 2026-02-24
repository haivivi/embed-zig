//! Test: Play very low volume sine wave while recording
//! Purpose: Check at what volume level acoustic feedback starts

const std = @import("std");
const pa = @import("portaudio");
const wav = @import("wav_writer");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;

var frame_count: u32 = 0;

fn duplexCallback(
    _: []const i16,
    output: []i16,
    _: usize,
    _: pa.TimeInfo,
    _: ?*anyopaque,
) pa.CallbackResult {
    // Output very low volume sine wave (-60dB = 0.001 amplitude)
    const amplitude: f32 = 0.001;  // -60dB
    for (0..output.len) |i| {
        const phase = @as(f32, @floatFromInt(frame_count * FRAME_SIZE + @as(u32, @intCast(i)))) * 2.0 * std.math.pi * 1000.0 / @as(f32, @floatFromInt(SAMPLE_RATE));
        const sample = @sin(phase) * amplitude * 32767.0;
        output[i] = @intFromFloat(sample);
    }
    frame_count += 1;
    return .Continue;
}

pub fn main() !void {
    try pa.init();
    defer pa.deinit();

    std.debug.print("\n=== Test: Play -60dB 1kHz tone + Record mic ===\n", .{});
    std.debug.print("If mic captures strong signal → acoustic feedback path exists\n\n", .{});

    var duplex: pa.DuplexStream(i16) = undefined;
    duplex.init(.{
        .sample_rate = @floatFromInt(SAMPLE_RATE),
        .channels = 1,
        .frames_per_buffer = FRAME_SIZE * 2,
    }, duplexCallback, null) catch return error.PortAudioError;
    defer duplex.close();


    // Record using separate input stream
    const InputStream = pa.InputStream(i16);
    var stream = try InputStream.open(.{
        .sample_rate = @floatFromInt(SAMPLE_RATE),
        .channels = 1,
        .frames_per_buffer = FRAME_SIZE,
    });
    defer stream.close();
    try stream.start();

    var mic_wav = try wav.WavWriter.init("low_volume_mic.wav", SAMPLE_RATE);
    defer mic_wav.close() catch {};

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var fcount: usize = 0;

    const deadline = std.time.milliTimestamp() + 5000;  // 5 seconds
    while (std.time.milliTimestamp() < deadline) {
        stream.read(&mic_buf) catch continue;
        try mic_wav.writeSamples(&mic_buf);

        fcount += 1;
        if (fcount % 50 == 0) {
            var mic_e: f64 = 0;
            for (0..FRAME_SIZE) |i| {
                const mv: f64 = @floatFromInt(mic_buf[i]);
                mic_e += mv * mv;
            }
            const mr = @sqrt(mic_e / FRAME_SIZE);
            std.debug.print("[{d}s] mic_rms={d:.0}\n", .{ fcount / 100, mr });
        }
    }

    std.debug.print("\nIf mic_rms >> 50 (expected 1kHz @ -60dB SPL), feedback exists.\n", .{});
    std.debug.print("Saved: low_volume_mic.wav\n", .{});
}
