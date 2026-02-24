//! Test: Play SILENCE while recording mic
//! Purpose: Determine if noise is acoustic feedback or digital noise

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

    try pa.init();
    defer pa.deinit();

    std.debug.print("\n=== Test: Play SILENCE + Record mic ===\n", .{});
    std.debug.print("If mic is quiet → noise is acoustic feedback\n", .{});
    std.debug.print("If mic is noisy → noise is digital/PortAudio issue\n\n", .{});

    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var duplex = try da.DuplexAudio.init(allocator);
    defer duplex.stop();

    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();

    var mic_wav = try wav.WavWriter.init("silence_duplex_mic.wav", SAMPLE_RATE);

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    const silence: [FRAME_SIZE]i16 = [_]i16{0} ** FRAME_SIZE;
    var frame_count: usize = 0;

    const deadline = std.time.milliTimestamp() + DURATION_S * 1000;
    while (std.time.milliTimestamp() < deadline) {
        _ = mic_drv.read(&mic_buf) catch continue;
        _ = spk_drv.write(&silence) catch continue;
        try mic_wav.writeSamples(&mic_buf);

        frame_count += 1;
        if (frame_count % 50 == 0) {
            var e: f64 = 0;
            for (&mic_buf) |s| {
                const v: f64 = @floatFromInt(s);
                e += v * v;
            }
            std.debug.print("[{d:.1}s] mic_rms={d:.0}\n", .{
                @as(f64, @floatFromInt(frame_count)) / 100.0,
                @sqrt(e / FRAME_SIZE),
            });
        }
    }

    try mic_wav.close();
    std.debug.print("\nSaved: silence_duplex_mic.wav\n\n", .{});
}
