//! E1 variant: Record mic while playing silence
//! Purpose: Isolate if noise comes from AEC processing or acoustic feedback

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");
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

    std.debug.print("\n=== E1 Variant: AEC processing but SILENCE output ===\n", .{});
    std.debug.print("This tests if noise is from AEC algorithm or acoustic feedback\n\n", .{});

    try pa.init();
    defer pa.deinit();

    var duplex = try da.DuplexAudio.init(allocator);
    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();
    var ref_rdr = duplex.refReader();

    var aec = try audio.aec3.aec3.Aec3.init(allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
    });
    defer aec.deinit();

    defer duplex.stop();

    var mic_wav = try wav.WavWriter.init("e1_silence_mic.wav", SAMPLE_RATE);
    var clean_wav = try wav.WavWriter.init("e1_silence_clean.wav", SAMPLE_RATE);
    defer mic_wav.close() catch {};
    defer clean_wav.close() catch {};

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = undefined;
    var clean: [FRAME_SIZE]i16 = undefined;
    var silence: [FRAME_SIZE]i16 = undefined;
    @memset(&silence, 0);

    var frame_count: usize = 0;
    const deadline = std.time.milliTimestamp() + DURATION_S * 1000;

    while (std.time.milliTimestamp() < deadline) {
        _ = mic_drv.read(&mic_buf) catch continue;
        _ = ref_rdr.read(&ref_buf) catch continue;

        // Run AEC to get clean output (for recording/analysis)
        aec.process(&mic_buf, &ref_buf, &clean);

        // BUT: Play silence instead of clean output
        _ = spk_drv.write(&silence) catch continue;

        // Record both mic and clean for analysis
        try mic_wav.writeSamples(&mic_buf);
        try clean_wav.writeSamples(&clean);

        frame_count += 1;
        if (frame_count % 100 == 0) {
            var mic_e: f64 = 0;
            var cln_e: f64 = 0;
            for (0..FRAME_SIZE) |i| {
                const mv: f64 = @floatFromInt(mic_buf[i]);
                const cv: f64 = @floatFromInt(clean[i]);
                mic_e += mv * mv;
                cln_e += cv * cv;
            }
            const mr = @sqrt(mic_e / FRAME_SIZE);
            const cr = @sqrt(cln_e / FRAME_SIZE);
            std.debug.print("[{d}s] mic={d:.0} clean={d:.0}\n", .{ frame_count / 100, mr, cr });
        }
    }

    std.debug.print("\n[E1-Silence] Done. {d} frames.\n", .{frame_count});
    std.debug.print("WAV files: e1_silence_mic.wav, e1_silence_clean.wav\n", .{});
    std.debug.print("\nAnalysis:\n", .{});
    std.debug.print("- If mic is BROADBAND → noise is from environment (not feedback)\n", .{});
    std.debug.print("- If mic is LOW-FREQ → noise was acoustic feedback (now eliminated)\n", .{});
}
