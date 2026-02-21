//! Step 3: Speaker 440Hz + Mic + AEC — no monitor feedback
//!
//! Full-duplex callback: speaker plays 440Hz, mic captures, AEC removes echo.
//! Clean audio is NOT written back to speaker (no feedback loop).
//! Saves: speaker.wav, mic_raw.wav, aec_clean.wav
//! Measures ERLE every 500ms.

const std = @import("std");
const pa = @import("portaudio");
const speexdsp = @import("speexdsp");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 5;
const TOTAL_SAMPLES = SAMPLE_RATE * DURATION_S;
const TONE_FREQ: f64 = 440.0;
const TONE_AMP: f64 = 10000.0;

const State = struct {
    echo: *speexdsp.EchoState,
    pp: *speexdsp.Preprocess,
    phase_idx: usize = 0,

    speaker_rec: []i16,
    mic_rec: []i16,
    clean_rec: []i16,
    pos: usize = 0,

    mic_energy_acc: f64 = 0,
    clean_energy_acc: f64 = 0,
    frame_count: u32 = 0,
};

fn callback(
    input: []const i16,
    output: []i16,
    _: usize,
    user_data: ?*anyopaque,
) pa.CallbackResult {
    const state: *State = @ptrCast(@alignCast(user_data));

    // 1. Generate 440Hz tone → speaker output (this is the AEC reference)
    for (output, 0..) |*s, i| {
        const t: f64 = @as(f64, @floatFromInt(state.phase_idx + i)) / @as(f64, @floatFromInt(SAMPLE_RATE));
        s.* = @intFromFloat(@sin(t * TONE_FREQ * 2.0 * std.math.pi) * TONE_AMP);
    }

    // 2. AEC: cancel speaker echo from mic
    var clean: [FRAME_SIZE]i16 = undefined;
    state.echo.cancellation(input.ptr, output.ptr, &clean);

    // 3. NS
    _ = state.pp.run(&clean);

    // 4. Record all three signals
    if (state.pos + output.len <= state.speaker_rec.len) {
        @memcpy(state.speaker_rec[state.pos..][0..output.len], output);
        @memcpy(state.mic_rec[state.pos..][0..input.len], input);
        @memcpy(state.clean_rec[state.pos..][0..output.len], &clean);
        state.pos += output.len;
    }

    // 5. ERLE measurement
    for (input[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.mic_energy_acc += v * v;
    }
    for (clean[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.clean_energy_acc += v * v;
    }
    state.frame_count += 1;
    state.phase_idx += output.len;

    if (state.frame_count >= 50) {
        const n_samples: f64 = @floatFromInt(state.frame_count * FRAME_SIZE);
        const mic_rms = @sqrt(state.mic_energy_acc / n_samples);
        const clean_rms = @sqrt(state.clean_energy_acc / n_samples);
        const erle = if (clean_rms > 1.0) 20.0 * std.math.log10(mic_rms / clean_rms) else 60.0;

        std.debug.print("[aec] ERLE={d:.1}dB  mic_rms={d:.0} clean_rms={d:.0}\n", .{
            erle, mic_rms, clean_rms,
        });
        state.mic_energy_acc = 0;
        state.clean_energy_acc = 0;
        state.frame_count = 0;
    }

    // Speaker output is ONLY the tone — no clean audio mixed in (no feedback)

    if (state.pos >= TOTAL_SAMPLES) return .Complete;
    return .Continue;
}

fn writeWav(path: []const u8, samples: []const i16, sample_rate: u32) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const data_size: u32 = @intCast(samples.len * 2);
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], 36 + data_size, .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little);
    std.mem.writeInt(u16, hdr[22..24], 1, .little);
    std.mem.writeInt(u32, hdr[24..28], sample_rate, .little);
    std.mem.writeInt(u32, hdr[28..32], sample_rate * 2, .little);
    std.mem.writeInt(u16, hdr[32..34], 2, .little);
    std.mem.writeInt(u16, hdr[34..36], 16, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_size, .little);
    try file.writeAll(&hdr);
    try file.writeAll(std.mem.sliceAsBytes(samples));
}

fn goertzel(samples: []const i16, freq: f64, sr: f64) f64 {
    const n: f64 = @floatFromInt(samples.len);
    const k = @round(freq * n / sr);
    const w = 2.0 * std.math.pi * k / n;
    const coeff = 2.0 * @cos(w);
    var s0: f64 = 0;
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (samples) |s| {
        s0 = @as(f64, @floatFromInt(s)) + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Step 3: Speaker 440Hz + Mic + AEC (no feedback) ===\n", .{});
    std.debug.print("Duration: {d}s. No clean audio written to speaker.\n\n", .{DURATION_S});

    try pa.init();
    defer pa.deinit();

    if (pa.deviceInfo(pa.defaultInputDevice())) |info| {
        std.debug.print("Input:  {s}\n", .{info.name});
    }
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| {
        std.debug.print("Output: {s}\n\n", .{info.name});
    }

    // SpeexDSP AEC + NS
    speexdsp.setAllocator(allocator);
    var echo = try speexdsp.EchoState.init(@intCast(FRAME_SIZE), 8000);
    defer {
        speexdsp.setAllocator(allocator);
        echo.deinit();
    }
    echo.setSampleRate(@intCast(SAMPLE_RATE));

    var pp = try speexdsp.Preprocess.init(@intCast(FRAME_SIZE), @intCast(SAMPLE_RATE));
    defer {
        speexdsp.setAllocator(allocator);
        pp.deinit();
    }
    pp.setDenoise(-30);
    pp.enableDenoise(true);
    pp.setEchoState(&echo);

    // Recording buffers
    const speaker_rec = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(speaker_rec);
    const mic_rec = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(mic_rec);
    const clean_rec = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(clean_rec);

    var state = State{
        .echo = &echo,
        .pp = &pp,
        .speaker_rec = speaker_rec,
        .mic_rec = mic_rec,
        .clean_rec = clean_rec,
    };

    var stream: pa.DuplexStream(i16) = undefined;
    try stream.init(.{
        .sample_rate = SAMPLE_RATE,
        .channels = 1,
        .frames_per_buffer = FRAME_SIZE,
    }, callback, &state);
    defer stream.close();

    try stream.start();
    std.debug.print("Running...\n\n", .{});

    while (state.pos < TOTAL_SAMPLES) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    std.Thread.sleep(200 * std.time.ns_per_ms);
    stream.stop() catch {};

    const n = state.pos;
    std.debug.print("\nRecorded {d} samples ({d}ms)\n\n", .{ n, n * 1000 / SAMPLE_RATE });

    // Goertzel analysis: 440Hz power in mic vs clean
    const last_1s_start = if (n > SAMPLE_RATE) n - SAMPLE_RATE else 0;
    const mic_last = mic_rec[last_1s_start..n];
    const clean_last = clean_rec[last_1s_start..n];

    const mic_440 = goertzel(mic_last, 440.0, @floatFromInt(SAMPLE_RATE));
    const clean_440 = goertzel(clean_last, 440.0, @floatFromInt(SAMPLE_RATE));
    const suppression = clean_440 / @max(mic_440, 1.0);

    std.debug.print("Last 1s Goertzel @ 440Hz:\n", .{});
    std.debug.print("  mic:   {d:.1}dB\n", .{10.0 * @log10(@max(mic_440, 1.0))});
    std.debug.print("  clean: {d:.1}dB\n", .{10.0 * @log10(@max(clean_440, 1.0))});
    std.debug.print("  440Hz suppression: {d:.2}% ({d:.1}dB)\n", .{
        suppression * 100.0,
        10.0 * @log10(@max(1.0 / @max(suppression, 0.0001), 1.0)),
    });

    if (suppression < 0.1) {
        std.debug.print("\nVERDICT: AEC suppressed 440Hz by >90%. PASS.\n", .{});
    } else if (suppression < 0.3) {
        std.debug.print("\nVERDICT: AEC suppressed 440Hz by >70%. MARGINAL.\n", .{});
    } else {
        std.debug.print("\nVERDICT: AEC failed to suppress 440Hz ({d:.0}% remains). FAIL.\n", .{suppression * 100.0});
    }

    try writeWav("/tmp/step3_speaker.wav", speaker_rec[0..n], SAMPLE_RATE);
    try writeWav("/tmp/step3_mic_raw.wav", mic_rec[0..n], SAMPLE_RATE);
    try writeWav("/tmp/step3_aec_clean.wav", clean_rec[0..n], SAMPLE_RATE);
    std.debug.print("\nSaved:\n  /tmp/step3_speaker.wav\n  /tmp/step3_mic_raw.wav\n  /tmp/step3_aec_clean.wav\n\n", .{});
}
