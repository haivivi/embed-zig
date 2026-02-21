//! Step 5: TTS playback + AEC — real speech echo cancellation
//!
//! Plays pre-generated TTS WAV through speaker, mic captures echo,
//! AEC cancels it. No clean audio written to speaker.
//! After TTS ends, outputs silence to speaker while continuing mic capture.

const std = @import("std");
const pa = @import("portaudio");
const speexdsp = @import("speexdsp");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;

const State = struct {
    echo: *speexdsp.EchoState,
    pp: *speexdsp.Preprocess,

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

fn callback(
    input: []const i16,
    output: []i16,
    _: usize,
    user_data: ?*anyopaque,
) pa.CallbackResult {
    const state: *State = @ptrCast(@alignCast(user_data));

    // 1. Play TTS or silence
    if (state.tts_pos + output.len <= state.tts_data.len) {
        @memcpy(output, state.tts_data[state.tts_pos..][0..output.len]);
        state.tts_pos += output.len;
    } else {
        @memset(output, 0);
    }

    // 2. AEC
    var clean: [FRAME_SIZE]i16 = undefined;
    state.echo.cancellation(input.ptr, output.ptr, &clean);

    // 3. NS
    _ = state.pp.run(&clean);

    // 4. Record
    if (state.pos + output.len <= state.max_samples) {
        @memcpy(state.speaker_rec[state.pos..][0..output.len], output);
        @memcpy(state.mic_rec[state.pos..][0..input.len], input);
        @memcpy(state.clean_rec[state.pos..][0..output.len], &clean);
        state.pos += output.len;
    }

    // 5. ERLE every 500ms
    for (input[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.mic_energy_acc += v * v;
    }
    for (clean[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.clean_energy_acc += v * v;
    }
    state.frame_count += 1;

    if (state.frame_count >= 50) {
        const n_s: f64 = @floatFromInt(state.frame_count * FRAME_SIZE);
        const mic_rms = @sqrt(state.mic_energy_acc / n_s);
        const clean_rms = @sqrt(state.clean_energy_acc / n_s);
        const erle = if (clean_rms > 1.0) 20.0 * std.math.log10(mic_rms / clean_rms) else 60.0;
        const tts_active = state.tts_pos < state.tts_data.len;
        std.debug.print("[tts-aec] ERLE={d:.1}dB  mic={d:.0} clean={d:.0} {s}\n", .{
            erle, mic_rms, clean_rms,
            if (tts_active) "▶ playing" else "■ silence",
        });
        state.mic_energy_acc = 0;
        state.clean_energy_acc = 0;
        state.frame_count = 0;
    }

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

fn loadWav(path: []const u8, allocator: std.mem.Allocator) ![]i16 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const total = stat.size;
    var header: [44]u8 = undefined;
    _ = try file.read(&header);
    const data_bytes = total - 44;
    const n_samples = data_bytes / 2;
    const buf = try allocator.alloc(i16, n_samples);
    const bytes = std.mem.sliceAsBytes(buf);
    var read_total: usize = 0;
    while (read_total < bytes.len) {
        const n = try file.read(bytes[read_total..]);
        if (n == 0) break;
        read_total += n;
    }
    return buf;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Step 5: TTS Speech + AEC (no feedback) ===\n\n", .{});

    // Load TTS WAV
    const tts_data = try loadWav("/tmp/tts_ref.wav", allocator);
    defer allocator.free(tts_data);
    std.debug.print("Loaded TTS: {d} samples ({d:.1}s)\n", .{ tts_data.len, @as(f64, @floatFromInt(tts_data.len)) / 16000.0 });

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

    // Record for TTS duration + 2s tail
    const total_samples = tts_data.len + SAMPLE_RATE * 2;
    const spk = try allocator.alloc(i16, total_samples);
    defer allocator.free(spk);
    const mic = try allocator.alloc(i16, total_samples);
    defer allocator.free(mic);
    const cln = try allocator.alloc(i16, total_samples);
    defer allocator.free(cln);

    var state = State{
        .echo = &echo,
        .pp = &pp,
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
    std.debug.print("Playing TTS + recording...\n\n", .{});

    // Wait for TTS duration + 2s tail (timer-based, not pos-based)
    const wait_ms = (tts_data.len * 1000 / SAMPLE_RATE) + 2000;
    std.debug.print("Waiting {d}ms...\n", .{wait_ms});
    std.Thread.sleep(wait_ms * std.time.ns_per_ms);
    stream.stop() catch {};

    const n = state.pos;
    std.debug.print("\nRecorded {d} samples ({d:.1}s)\n", .{ n, @as(f64, @floatFromInt(n)) / 16000.0 });

    try writeWav("/tmp/step5_speaker.wav", spk[0..n], SAMPLE_RATE);
    try writeWav("/tmp/step5_mic_raw.wav", mic[0..n], SAMPLE_RATE);
    try writeWav("/tmp/step5_aec_clean.wav", cln[0..n], SAMPLE_RATE);
    std.debug.print("\nSaved:\n  /tmp/step5_speaker.wav\n  /tmp/step5_mic_raw.wav\n  /tmp/step5_aec_clean.wav\n\n", .{});
}
