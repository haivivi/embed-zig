//! Simplest test: mic → speaker, NO AEC
//!
//! In a quiet room, this should NOT produce feedback
//! because there's no initial noise to amplify.

const std = @import("std");
const pa = @import("portaudio");
const wav = @import("wav_writer");

const std_impl = @import("std_impl");
const da = std_impl.audio_engine;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 5;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    std.debug.print("\n=== Simplest Test: Mic → Speaker (NO AEC) ===\n", .{});
    std.debug.print("In quiet room, this should stay quiet.\n", .{});
    std.debug.print("If noise grows, there's a fundamental problem.\n\n", .{});

    try pa.init();
    defer pa.deinit();

    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var duplex = try da.DuplexAudio.init(allocator);
    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();

    defer duplex.stop();

    std.Thread.sleep(100 * std.time.ns_per_ms);
    const offset = duplex.getRefOffset();
    std.debug.print("Hardware offset: {d} samples\n\n", .{offset});

    var mic_wav = try wav.WavWriter.init("simple_mic.wav", SAMPLE_RATE);
    var spk_wav = try wav.WavWriter.init("simple_spk.wav", SAMPLE_RATE);

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var prev_rms: f64 = 0;

    const deadline = std.time.milliTimestamp() + DURATION_S * 1000;
    var frame_count: usize = 0;

    std.debug.print("Running for {d}s...\n\n", .{DURATION_S});

    while (std.time.milliTimestamp() < deadline) {
        _ = mic_drv.read(&mic_buf) catch continue;

        // Direct passthrough: mic → speaker (NO AEC, NO GAIN)
        _ = spk_drv.write(&mic_buf) catch continue;

        try mic_wav.writeSamples(&mic_buf);
        try spk_wav.writeSamples(&mic_buf);

        frame_count += 1;
        if (frame_count % 50 == 0) {
            var e: f64 = 0;
            var max_val: i16 = 0;
            for (&mic_buf) |s| {
                const v: f64 = @floatFromInt(s);
                e += v * v;
                if (@abs(s) > @abs(max_val)) max_val = s;
            }
            const rms = @sqrt(e / FRAME_SIZE);
            const growth = if (prev_rms > 10) rms / prev_rms else 1.0;
            prev_rms = rms;

            const warning = if (growth > 1.2) " ⚠️ GROWING!" else if (rms > 5000) " ⚠️ LOUD!" else "";
            std.debug.print("[{d:.1}s] mic_rms={d:>6.0} max={d:>6} growth={d:.2}{s}\n", .{
                @as(f64, @floatFromInt(frame_count)) / 100.0, rms, max_val, growth, warning,
            });
        }
    }

    try mic_wav.close();
    try spk_wav.close();

    std.debug.print("\nDone. Check simple_mic.wav and simple_spk.wav\n", .{});
    std.debug.print("If these are quiet, the problem is NOT in PortAudio.\n", .{});
    std.debug.print("If these have noise, there's a feedback loop or mic issue.\n\n", .{});
}
