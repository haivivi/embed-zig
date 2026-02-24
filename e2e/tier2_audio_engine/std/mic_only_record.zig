//! Simple mic-only recording test (no AEC, no speaker output)

const std = @import("std");
const pa = @import("portaudio");
const wav = @import("wav_writer");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 5;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Mic-Only Recording Test ===\n", .{});
    std.debug.print("Recording {d}s of raw mic input (no speaker, no AEC)\n\n", .{DURATION_S});

    try pa.init();
    defer pa.deinit();

    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input: {s}\n\n", .{info.name});

    // Input-only stream
    var stream = try pa.Stream.open(allocator, .{
        .input_channels = 1,
        .output_channels = 0,
        .sample_rate = @floatFromInt(SAMPLE_RATE),
        .frames_per_buffer = FRAME_SIZE,
    });
    defer stream.close();
    try stream.start();

    var mic_wav = try wav.WavWriter.init("mic_only.wav", SAMPLE_RATE);

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var frame_count: usize = 0;

    const deadline = std.time.milliTimestamp() + DURATION_S * 1000;
    std.debug.print(">>> RECORDING (stay silent) <<<\n\n", .{});

    while (std.time.milliTimestamp() < deadline) {
        _ = stream.read(&mic_buf) catch continue;
        try mic_wav.writeSamples(&mic_buf);

        frame_count += 1;
        if (frame_count % 50 == 0) {
            var e: f64 = 0;
            var max_val: i16 = 0;
            for (&mic_buf) |s| {
                const v: f64 = @floatFromInt(s);
                e += v * v;
                if (@abs(s) > @abs(max_val)) max_val = s;
            }
            std.debug.print("[{d:.1}s] rms={d:.0} max={d}\n", .{
                @as(f64, @floatFromInt(frame_count)) / 100.0,
                @sqrt(e / FRAME_SIZE),
                max_val,
            });
        }
    }

    try mic_wav.close();
    std.debug.print("\nDone. {d} frames. Output: mic_only.wav\n\n", .{frame_count});
}
