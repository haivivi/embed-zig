//! Step 2: Speaker plays 440Hz sine, mic records simultaneously.
//! Full-duplex callback — speaker output and mic input in one call.
//! Saves speaker_out.wav and mic_in.wav for comparison.

const std = @import("std");
const pa = @import("portaudio");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 3;
const TOTAL_SAMPLES = SAMPLE_RATE * DURATION_S;
const TONE_FREQ: f64 = 440.0;
const TONE_AMP: f64 = 10000.0;

const State = struct {
    speaker_rec: []i16,
    mic_rec: []i16,
    pos: usize = 0,
    phase_idx: usize = 0,
};

fn callback(
    input: []const i16,
    output: []i16,
    _: usize,
    _: pa.TimeInfo,
    user_data: ?*anyopaque,
) pa.CallbackResult {
    const state: *State = @ptrCast(@alignCast(user_data));

    // Generate 440Hz tone → speaker
    for (output, 0..) |*s, i| {
        const t: f64 = @as(f64, @floatFromInt(state.phase_idx + i)) / @as(f64, @floatFromInt(SAMPLE_RATE));
        s.* = @intFromFloat(@sin(t * TONE_FREQ * 2.0 * std.math.pi) * TONE_AMP);
    }
    state.phase_idx += output.len;

    // Record both
    if (state.pos + output.len <= state.speaker_rec.len) {
        @memcpy(state.speaker_rec[state.pos..][0..output.len], output);
        @memcpy(state.mic_rec[state.pos..][0..input.len], input);
        state.pos += output.len;
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

    std.debug.print("\n=== Step 2: Speaker 440Hz + Mic Record ===\n", .{});
    std.debug.print("Playing 440Hz tone ({d}s) and recording mic simultaneously.\n\n", .{DURATION_S});

    try pa.init();
    defer pa.deinit();

    if (pa.deviceInfo(pa.defaultInputDevice())) |info| {
        std.debug.print("Input:  {s}\n", .{info.name});
    }
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| {
        std.debug.print("Output: {s}\n\n", .{info.name});
    }

    const speaker_rec = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(speaker_rec);
    const mic_rec = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(mic_rec);

    var state = State{
        .speaker_rec = speaker_rec,
        .mic_rec = mic_rec,
    };

    var stream: pa.DuplexStream(i16) = undefined;
    try stream.init(.{
        .sample_rate = SAMPLE_RATE,
        .channels = 1,
        .frames_per_buffer = FRAME_SIZE,
    }, callback, &state);
    defer stream.close();

    try stream.start();

    // Wait for completion
    while (state.pos < TOTAL_SAMPLES) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    std.Thread.sleep(200 * std.time.ns_per_ms);
    stream.stop() catch {};

    // Analyze
    const recorded = state.pos;
    std.debug.print("Recorded {d} samples ({d}ms)\n\n", .{ recorded, recorded * 1000 / SAMPLE_RATE });

    // Speaker output analysis
    var spk_rms: f64 = 0;
    for (speaker_rec[0..recorded]) |s| {
        const v: f64 = @floatFromInt(s);
        spk_rms += v * v;
    }
    spk_rms = @sqrt(spk_rms / @as(f64, @floatFromInt(recorded)));

    // Mic input analysis
    var mic_rms: f64 = 0;
    for (mic_rec[0..recorded]) |s| {
        const v: f64 = @floatFromInt(s);
        mic_rms += v * v;
    }
    mic_rms = @sqrt(mic_rms / @as(f64, @floatFromInt(recorded)));

    // Goertzel: how much 440Hz is in the mic signal?
    const mic_440_power = goertzel(mic_rec[0..recorded], 440.0, @floatFromInt(SAMPLE_RATE));
    const mic_200_power = goertzel(mic_rec[0..recorded], 200.0, @floatFromInt(SAMPLE_RATE));
    const mic_1000_power = goertzel(mic_rec[0..recorded], 1000.0, @floatFromInt(SAMPLE_RATE));

    std.debug.print("Speaker output: RMS={d:.1}\n", .{spk_rms});
    std.debug.print("Mic input:      RMS={d:.1}\n", .{mic_rms});
    std.debug.print("\nMic Goertzel power:\n", .{});
    std.debug.print("  200Hz:  {d:.1}\n", .{10.0 * @log10(@max(mic_200_power, 1.0))});
    std.debug.print("  440Hz:  {d:.1}  ← this should be HIGH (speaker echo)\n", .{10.0 * @log10(@max(mic_440_power, 1.0))});
    std.debug.print("  1000Hz: {d:.1}\n", .{10.0 * @log10(@max(mic_1000_power, 1.0))});

    const ratio_440_vs_200 = mic_440_power / @max(mic_200_power, 1.0);

    if (ratio_440_vs_200 > 10.0) {
        std.debug.print("\nVERDICT: Mic captured 440Hz from speaker ({d:.0}x above 200Hz). PASS.\n", .{ratio_440_vs_200});
    } else {
        std.debug.print("\nVERDICT: 440Hz not dominant in mic ({d:.1}x vs 200Hz). Speaker echo too weak or mic issue.\n", .{ratio_440_vs_200});
    }

    try writeWav("/tmp/step2_speaker.wav", speaker_rec[0..recorded], SAMPLE_RATE);
    try writeWav("/tmp/step2_mic.wav", mic_rec[0..recorded], SAMPLE_RATE);
    std.debug.print("\nSaved:\n  /tmp/step2_speaker.wav\n  /tmp/step2_mic.wav\n\n", .{});
}
