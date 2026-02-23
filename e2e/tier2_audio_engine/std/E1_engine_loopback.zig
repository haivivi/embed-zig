//! E1: Mic → AEC → Speaker loopback (DuplexStream)
//!
//! Simplest possible AEC test. No Engine, no mixer, no tracks.
//! Just: mic.read() → aec3.process(mic, ref) → speaker.write(clean)
//!
//! Without AEC: you hear yourself with echo buildup (feedback).
//! With AEC: you hear yourself once, no echo.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");
const wav = @import("wav_writer");

const std_impl = @import("std_impl");
const da = std_impl.audio_engine;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 10;  // Shorter for testing (10s)

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== E1: Mic → AEC → Speaker (DuplexStream, no Engine) ===\n", .{});
    std.debug.print("Speak into mic. You should hear yourself, no echo.\n", .{});
    std.debug.print("Duration: {d}s\n\n", .{DURATION_S});

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var duplex = da.DuplexAudio.init();
    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();
    var ref_rdr = duplex.refReader();

    var aec = try audio.aec3.aec3.Aec3.init(allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
    });
    defer aec.deinit();

    try duplex.start();
    defer duplex.stop();

    // Create WAV file recorders
    var mic_wav = try wav.WavWriter.init("e1_mic.wav", SAMPLE_RATE);
    var ref_wav = try wav.WavWriter.init("e1_ref.wav", SAMPLE_RATE);
    var clean_wav = try wav.WavWriter.init("e1_clean.wav", SAMPLE_RATE);

    std.debug.print(">>> SPEAK NOW! Recording to e1_mic.wav, e1_ref.wav, e1_clean.wav <<<{d}s\n\n", .{DURATION_S});

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = undefined;
    var clean: [FRAME_SIZE]i16 = undefined;
    var frame_count: usize = 0;

    const deadline = std.time.milliTimestamp() + DURATION_S * 1000;

    while (std.time.milliTimestamp() < deadline) {
        _ = mic_drv.read(&mic_buf) catch continue;
        _ = ref_rdr.read(&ref_buf) catch continue;

        aec.process(&mic_buf, &ref_buf, &clean);

        _ = spk_drv.write(&clean) catch continue;

        // Record to WAV files
        try mic_wav.writeSamples(&mic_buf);
        try ref_wav.writeSamples(&ref_buf);
        try clean_wav.writeSamples(&clean);

        frame_count += 1;
        if (frame_count % 100 == 0) {
            var mic_e: f64 = 0;
            var ref_e: f64 = 0;
            var cln_e: f64 = 0;
            var ref_max: i16 = 0;
            var clean_max: i16 = 0;
            for (0..FRAME_SIZE) |i| {
                const mv: f64 = @floatFromInt(mic_buf[i]);
                const rv: f64 = @floatFromInt(ref_buf[i]);
                const cv: f64 = @floatFromInt(clean[i]);
                mic_e += mv * mv;
                ref_e += rv * rv;
                cln_e += cv * cv;
                if (ref_buf[i] > ref_max) ref_max = ref_buf[i];
                if (ref_buf[i] < -ref_max) ref_max = -ref_buf[i];
                if (clean[i] > clean_max) clean_max = clean[i];
                if (clean[i] < -clean_max) clean_max = -clean[i];
            }
            const mr = @sqrt(mic_e / FRAME_SIZE);
            const rr = @sqrt(ref_e / FRAME_SIZE);
            const cr = @sqrt(cln_e / FRAME_SIZE);
            // Show ratio of ref to mic - if ref >> mic, AEC will over-suppress
            const ratio = if (mr > 100) rr / mr else 0;
            std.debug.print("[{d}s] mic={d:.0} ref={d:.0} clean={d:.0} ratio={d:.2} ref_max={d} clean_max={d}\n", .{
                frame_count / 100, mr, rr, cr, ratio, ref_max, clean_max,
            });
        }
    }

    // Close WAV files (writes headers)
    try mic_wav.close();
    try ref_wav.close();
    try clean_wav.close();

    std.debug.print("\n[E1] Done. {d} frames processed.\n", .{frame_count});
    std.debug.print("WAV files saved: e1_mic.wav, e1_ref.wav, e1_clean.wav\n\n", .{});
}
