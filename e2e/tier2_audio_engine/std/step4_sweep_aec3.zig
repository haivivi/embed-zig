//! Step 4: Sweep 200→4000Hz + AEC3 — broadband, no feedback
//! Duration: 10s. This is where SpeexDSP scored 0dB.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");
const Aec3 = audio.aec3.aec3.Aec3;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 10;
const TOTAL_SAMPLES = SAMPLE_RATE * DURATION_S;

const State = struct {
    aec: *Aec3,
    sweep_idx: usize = 0,
    speaker_rec: []i16,
    mic_rec: []i16,
    clean_rec: []i16,
    pos: usize = 0,
    mic_energy_acc: f64 = 0,
    clean_energy_acc: f64 = 0,
    frame_count: u32 = 0,
};

fn callback(input: []const i16, output: []i16, _: usize, user_data: ?*anyopaque) pa.CallbackResult {
    const state: *State = @ptrCast(@alignCast(user_data));
    const sr: f64 = @floatFromInt(SAMPLE_RATE);

    for (output, 0..) |*s, i| {
        const t: f64 = @as(f64, @floatFromInt(state.sweep_idx + i)) / sr;
        const progress = @mod(t, 5.0) / 5.0;
        const freq = 200.0 + 3800.0 * progress;
        s.* = @intFromFloat(@sin(2.0 * std.math.pi * freq * t) * 8000.0);
    }

    var clean: [FRAME_SIZE]i16 = undefined;
    state.aec.process(input, output, &clean);

    if (state.pos + output.len <= state.speaker_rec.len) {
        @memcpy(state.speaker_rec[state.pos..][0..output.len], output);
        @memcpy(state.mic_rec[state.pos..][0..input.len], input);
        @memcpy(state.clean_rec[state.pos..][0..output.len], &clean);
        state.pos += output.len;
    }

    for (input[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.mic_energy_acc += v * v;
    }
    for (clean) |s| {
        const v: f64 = @floatFromInt(s);
        state.clean_energy_acc += v * v;
    }
    state.frame_count += 1;
    state.sweep_idx += output.len;

    if (state.frame_count >= 50) {
        const n: f64 = @floatFromInt(state.frame_count * FRAME_SIZE);
        const mic_rms = @sqrt(state.mic_energy_acc / n);
        const clean_rms = @sqrt(state.clean_energy_acc / n);
        const erle = if (clean_rms > 1.0) 20.0 * std.math.log10(mic_rms / clean_rms) else 60.0;
        std.debug.print("  [{d}s] ERLE={d:.1}dB  mic={d:.0} clean={d:.0}\n", .{
            state.pos / SAMPLE_RATE, erle, mic_rms, clean_rms,
        });
        state.mic_energy_acc = 0;
        state.clean_energy_acc = 0;
        state.frame_count = 0;
    }

    if (state.pos >= TOTAL_SAMPLES) return .Complete;
    return .Continue;
}

fn writeWav(path: []const u8, samples: []const i16) !void {
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
    std.mem.writeInt(u32, hdr[24..28], SAMPLE_RATE, .little);
    std.mem.writeInt(u32, hdr[28..32], SAMPLE_RATE * 2, .little);
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

    std.debug.print("\n=== Step 4: Sweep 200→4kHz + AEC3 ({d}s) ===\n", .{DURATION_S});
    std.debug.print("Stay QUIET. SpeexDSP scored 0dB here.\n\n", .{});

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var aec = try Aec3.init(allocator, .{ .frame_size = FRAME_SIZE, .num_partitions = 50 });
    defer aec.deinit();

    const spk = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(spk);
    const mic = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(mic);
    const cln = try allocator.alloc(i16, TOTAL_SAMPLES);
    defer allocator.free(cln);

    var state = State{ .aec = &aec, .speaker_rec = spk, .mic_rec = mic, .clean_rec = cln };

    var stream: pa.DuplexStream(i16) = undefined;
    try stream.init(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE }, callback, &state);
    defer stream.close();

    try stream.start();
    while (state.pos < TOTAL_SAMPLES) std.Thread.sleep(100 * std.time.ns_per_ms);
    std.Thread.sleep(300 * std.time.ns_per_ms);
    stream.stop() catch {};

    const n = state.pos;
    std.debug.print("\nRecorded {d} samples ({d}s)\n", .{ n, n / SAMPLE_RATE });

    try writeWav("/tmp/step4_speaker.wav", spk[0..n]);
    try writeWav("/tmp/step4_mic.wav", mic[0..n]);
    try writeWav("/tmp/step4_clean.wav", cln[0..n]);
    std.debug.print("Saved: /tmp/step4_speaker.wav, step4_mic.wav, step4_clean.wav\n\n", .{});
}
