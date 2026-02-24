const std = @import("std");
const audio = @import("audio");
const sim = audio.sim_audio;
const aec3 = audio.aec3.aec3;
const wav = @import("wav_writer");

const FRAME_SIZE: usize = 160;
const SAMPLE_RATE: u32 = 16000;
const NUM_FRAMES: usize = 500;

pub fn main() !void {
    std.debug.print("\n=== SimAudio E1 Test (Generate WAV files) ===\n\n", .{});

    const Sim = sim.SimAudio(.{
        .echo_delay_samples = 350,
        .echo_gain = 0.5,
        .has_hardware_loopback = true,
        .ambient_noise_rms = 0,
        .resonance_freq = 0,
        .resonance_gain = 0,
        .resonance_q = 0,
    });
    var sim_audio = Sim.init();
    try sim_audio.start();
    defer sim_audio.stop();

    var spk = sim_audio.speaker();
    var mic_drv = sim_audio.mic();
    var rdr = sim_audio.refReader();

    var aec = try aec3.Aec3.init(std.heap.page_allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .num_partitions = 10,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    var mic_wav = try wav.WavWriter.init("sim_mic.wav", SAMPLE_RATE);
    defer mic_wav.close();

    var ref_wav = try wav.WavWriter.init("sim_ref.wav", SAMPLE_RATE);
    defer ref_wav.close();

    var clean_wav = try wav.WavWriter.init("sim_clean.wav", SAMPLE_RATE);
    defer clean_wav.close();

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = undefined;
    var clean: [FRAME_SIZE]i16 = undefined;

    std.debug.print("Running {d} frames...\n", .{NUM_FRAMES});

    for (0..NUM_FRAMES) |frame| {
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);
        _ = try spk.write(&clean);

        try mic_wav.writeSamples(&mic_buf);
        try ref_wav.writeSamples(&ref_buf);
        try clean_wav.writeSamples(&clean);

        if (frame % 100 == 0) {
            var mic_e: f64 = 0;
            var ref_e: f64 = 0;
            var clean_e: f64 = 0;
            for (0..FRAME_SIZE) |i| {
                mic_e += @as(f64, @floatFromInt(mic_buf[i])) * @as(f64, @floatFromInt(mic_buf[i]));
                ref_e += @as(f64, @floatFromInt(ref_buf[i])) * @as(f64, @floatFromInt(ref_buf[i]));
                clean_e += @as(f64, @floatFromInt(clean[i])) * @as(f64, @floatFromInt(clean[i]));
            }
            std.debug.print("[{d}] mic={d:.0} ref={d:.0} clean={d:.0}\n", .{
                frame,
                @sqrt(mic_e / FRAME_SIZE),
                @sqrt(ref_e / FRAME_SIZE),
                @sqrt(clean_e / FRAME_SIZE),
            });
        }
    }

    std.debug.print("\nDone! Saved:\n", .{});
    std.debug.print("  - sim_mic.wav (麦克风输入)\n", .{});
    std.debug.print("  - sim_ref.wav (参考信号/speaker)\n", .{});
    std.debug.print("  - sim_clean.wav (AEC处理后输出)\n", .{});
}
