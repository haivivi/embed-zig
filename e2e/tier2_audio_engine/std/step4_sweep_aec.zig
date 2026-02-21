//! Step 4: Sweep + AEC — broadband echo cancellation, no feedback
//!
//! Speaker plays 200Hz→4000Hz chirp, mic captures, AEC cancels.
//! Clean audio NOT written to speaker. Saves WAV files.

const std = @import("std");
const pa = @import("portaudio");
const speexdsp = @import("speexdsp");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 5;
const TOTAL_SAMPLES = SAMPLE_RATE * DURATION_S;

const State = struct {
    echo: *speexdsp.EchoState,
    pp: *speexdsp.Preprocess,
    sweep_idx: usize = 0,

    speaker_rec: []i16,
    mic_rec: []i16,
    clean_rec: []i16,
    pos: usize = 0,

    mic_energy_acc: f64 = 0,
    clean_energy_acc: f64 = 0,
    frame_count: u32 = 0,
};

fn generateSweep(buf: []i16, start_idx: usize) void {
    const sr: f64 = @floatFromInt(SAMPLE_RATE);
    const f_start: f64 = 200.0;
    const f_end: f64 = 4000.0;
    const sweep_dur: f64 = 5.0;
    const amp: f64 = 8000.0;

    for (buf, 0..) |*s, i| {
        const t: f64 = @as(f64, @floatFromInt(start_idx + i)) / sr;
        const progress = @mod(t, sweep_dur) / sweep_dur;
        const freq = f_start + (f_end - f_start) * progress;
        const phase = 2.0 * std.math.pi * freq * t;
        s.* = @intFromFloat(@sin(phase) * amp);
    }
}

fn callback(
    input: []const i16,
    output: []i16,
    _: usize,
    user_data: ?*anyopaque,
) pa.CallbackResult {
    const state: *State = @ptrCast(@alignCast(user_data));

    // 1. Generate sweep → speaker
    generateSweep(output, state.sweep_idx);

    // 2. AEC
    var clean: [FRAME_SIZE]i16 = undefined;
    state.echo.cancellation(input.ptr, output.ptr, &clean);

    // 3. NS
    _ = state.pp.run(&clean);

    // 4. Record
    if (state.pos + output.len <= state.speaker_rec.len) {
        @memcpy(state.speaker_rec[state.pos..][0..output.len], output);
        @memcpy(state.mic_rec[state.pos..][0..input.len], input);
        @memcpy(state.clean_rec[state.pos..][0..output.len], &clean);
        state.pos += output.len;
    }

    // 5. ERLE
    for (input[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.mic_energy_acc += v * v;
    }
    for (clean[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.clean_energy_acc += v * v;
    }
    state.frame_count += 1;
    state.sweep_idx += output.len;

    if (state.frame_count >= 50) {
        const n_s: f64 = @floatFromInt(state.frame_count * FRAME_SIZE);
        const mic_rms = @sqrt(state.mic_energy_acc / n_s);
        const clean_rms = @sqrt(state.clean_energy_acc / n_s);
        const erle = if (clean_rms > 1.0) 20.0 * std.math.log10(mic_rms / clean_rms) else 60.0;
        std.debug.print("[sweep-aec] ERLE={d:.1}dB  mic={d:.0} clean={d:.0}\n", .{ erle, mic_rms, clean_rms });
        state.mic_energy_acc = 0;
        state.clean_energy_acc = 0;
        state.frame_count = 0;
    }

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Step 4: Sweep (200-4000Hz) + AEC (no feedback) ===\n\n", .{});

    try pa.init();
    defer pa.deinit();

    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    speexdsp.setAllocator(allocator);
    var echo = try speexdsp.EchoState.init(@intCast(FRAME_SIZE), 8000);
    defer { speexdsp.setAllocator(allocator); echo.deinit(); }
    echo.setSampleRate(@intCast(SAMPLE_RATE));

    var pp = try speexdsp.Preprocess.init(@intCast(FRAME_SIZE), @intCast(SAMPLE_RATE));
    defer { speexdsp.setAllocator(allocator); pp.deinit(); }
    pp.setDenoise(-30);
    pp.enableDenoise(true);
    pp.setEchoState(&echo);

    const spk = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(spk);
    const mic = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(mic);
    const cln = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(cln);

    var state = State{ .echo = &echo, .pp = &pp, .speaker_rec = spk, .mic_rec = mic, .clean_rec = cln };

    var stream: pa.DuplexStream(i16) = undefined;
    try stream.init(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE }, callback, &state);
    defer stream.close();

    try stream.start();
    while (state.pos < TOTAL_SAMPLES) std.Thread.sleep(100 * std.time.ns_per_ms);
    std.Thread.sleep(200 * std.time.ns_per_ms);
    stream.stop() catch {};

    const n = state.pos;
    std.debug.print("\nRecorded {d} samples ({d}ms)\n", .{ n, n * 1000 / SAMPLE_RATE });

    try writeWav("/tmp/step4_speaker.wav", spk[0..n], SAMPLE_RATE);
    try writeWav("/tmp/step4_mic_raw.wav", mic[0..n], SAMPLE_RATE);
    try writeWav("/tmp/step4_aec_clean.wav", cln[0..n], SAMPLE_RATE);
    std.debug.print("\nSaved:\n  /tmp/step4_speaker.wav\n  /tmp/step4_mic_raw.wav\n  /tmp/step4_aec_clean.wav\n\n", .{});
}
