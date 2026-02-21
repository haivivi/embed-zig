//! Step 5: TTS speech + AEC3 — no feedback
//! Plays /tmp/tts_ref.wav through speaker, mic captures, AEC3 cancels.
//! SpeexDSP scored 2-6dB on speech segments.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");
const Aec3 = audio.aec3.aec3.Aec3;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;

const State = struct {
    aec: *Aec3,
    tts_data: []const i16,
    tts_pos: usize = 0,
    speaker_rec: []i16,
    mic_rec: []i16,
    clean_rec: []i16,
    pos: usize = 0,
    max_samples: usize,
    mic_energy_acc: f64 = 0,
    clean_energy_acc: f64 = 0,
    frame_count: u32 = 0,
};

fn callback(input: []const i16, output: []i16, _: usize, user_data: ?*anyopaque) pa.CallbackResult {
    const state: *State = @ptrCast(@alignCast(user_data));

    if (state.tts_pos + output.len <= state.tts_data.len) {
        @memcpy(output, state.tts_data[state.tts_pos..][0..output.len]);
        state.tts_pos += output.len;
    } else {
        @memset(output, 0);
    }

    var clean: [FRAME_SIZE]i16 = undefined;
    state.aec.process(input, output, &clean);

    if (state.pos + output.len <= state.max_samples) {
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

    if (state.frame_count >= 50) {
        const n: f64 = @floatFromInt(state.frame_count * FRAME_SIZE);
        const mic_rms = @sqrt(state.mic_energy_acc / n);
        const clean_rms = @sqrt(state.clean_energy_acc / n);
        const erle = if (clean_rms > 1.0) 20.0 * std.math.log10(mic_rms / clean_rms) else 60.0;
        const tts_active = state.tts_pos < state.tts_data.len;
        std.debug.print("  [{d:.1}s] ERLE={d:.1}dB  mic={d:.0} clean={d:.0} {s}\n", .{
            @as(f64, @floatFromInt(state.pos)) / @as(f64, @floatFromInt(SAMPLE_RATE)),
            erle, mic_rms, clean_rms,
            if (tts_active) "▶" else "■",
        });
        state.mic_energy_acc = 0;
        state.clean_energy_acc = 0;
        state.frame_count = 0;
    }

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

fn loadWav(path: []const u8, allocator: std.mem.Allocator) ![]i16 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    var header: [44]u8 = undefined;
    _ = try file.read(&header);
    const n_samples = (stat.size - 44) / 2;
    const buf = try allocator.alloc(i16, n_samples);
    const bytes = std.mem.sliceAsBytes(buf);
    var total: usize = 0;
    while (total < bytes.len) {
        const n = try file.read(bytes[total..]);
        if (n == 0) break;
        total += n;
    }
    return buf;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Step 5: TTS + AEC3 ===\n", .{});
    std.debug.print("Stay QUIET.\n\n", .{});

    const tts_data = loadWav("/tmp/tts_ref.wav", allocator) catch {
        std.debug.print("ERROR: /tmp/tts_ref.wav not found. Generate TTS first.\n", .{});
        return;
    };
    defer allocator.free(tts_data);
    std.debug.print("TTS: {d} samples ({d:.1}s)\n", .{ tts_data.len, @as(f64, @floatFromInt(tts_data.len)) / 16000.0 });

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var aec = try Aec3.init(allocator, .{ .frame_size = FRAME_SIZE, .num_partitions = 50 });
    defer aec.deinit();

    const total_samples = tts_data.len + SAMPLE_RATE * 3;
    const spk = try allocator.alloc(i16, total_samples);
    defer allocator.free(spk);
    const mic = try allocator.alloc(i16, total_samples);
    defer allocator.free(mic);
    const cln = try allocator.alloc(i16, total_samples);
    defer allocator.free(cln);

    var state = State{
        .aec = &aec,
        .tts_data = tts_data,
        .speaker_rec = spk,
        .mic_rec = mic,
        .clean_rec = cln,
        .max_samples = total_samples,
    };

    var stream: pa.DuplexStream(i16) = undefined;
    try stream.init(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE }, callback, &state);
    defer stream.close();

    try stream.start();
    const wait_ms = tts_data.len * 1000 / SAMPLE_RATE + 3000;
    std.debug.print("Running {d}ms...\n\n", .{wait_ms});
    std.Thread.sleep(@as(u64, wait_ms) * std.time.ns_per_ms);
    stream.stop() catch {};

    const n = state.pos;
    std.debug.print("\nRecorded {d} samples ({d:.1}s)\n", .{ n, @as(f64, @floatFromInt(n)) / 16000.0 });

    try writeWav("/tmp/step5_speaker.wav", spk[0..n]);
    try writeWav("/tmp/step5_mic.wav", mic[0..n]);
    try writeWav("/tmp/step5_clean.wav", cln[0..n]);
    std.debug.print("Saved: /tmp/step5_speaker.wav, step5_mic.wav, step5_clean.wav\n\n", .{});
}
