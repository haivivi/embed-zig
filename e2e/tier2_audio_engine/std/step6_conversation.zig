//! Step 6: Real-time conversation — TTS + your voice + AEC + clean playback
//!
//! Speaker plays TTS (looping), mic captures TTS echo + your voice,
//! AEC removes TTS echo, clean audio (your voice) mixed back into speaker.
//! Clean monitor gain is low (0.3) to prevent positive feedback.
//!
//! Speak into mic while TTS plays — you should hear yourself.

const std = @import("std");
const pa = @import("portaudio");
const speexdsp = @import("speexdsp");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 15;
const MONITOR_GAIN: f32 = 0.3;

const State = struct {
    echo: *speexdsp.EchoState,
    pp: *speexdsp.Preprocess,

    tts_data: []const i16,
    tts_pos: usize = 0,

    // Previous frame's clean audio for monitor (1-frame delay)
    prev_clean: [FRAME_SIZE]i16 = [_]i16{0} ** FRAME_SIZE,

    mic_energy_acc: f64 = 0,
    clean_energy_acc: f64 = 0,
    frame_count: u32 = 0,
    total_frames: u32 = 0,
};

fn callback(
    input: []const i16,
    output: []i16,
    _: usize,
    user_data: ?*anyopaque,
) pa.CallbackResult {
    const state: *State = @ptrCast(@alignCast(user_data));

    // 1. Get TTS frame
    var tts: [FRAME_SIZE]i16 = undefined;
    if (state.tts_pos + output.len <= state.tts_data.len) {
        @memcpy(&tts, state.tts_data[state.tts_pos..][0..output.len]);
        state.tts_pos += output.len;
    } else {
        @memset(&tts, 0);
    }

    // 2. Build actual speaker output = TTS + prev_clean * monitor_gain
    //    This is what the speaker actually plays, and what AEC uses as ref.
    for (output, 0..) |*s, i| {
        const t: i32 = tts[i];
        const m: i32 = @intFromFloat(@as(f32, @floatFromInt(state.prev_clean[i])) * MONITOR_GAIN);
        s.* = @intCast(std.math.clamp(t + m, -32768, 32767));
    }

    // 3. AEC: ref = actual output (TTS + monitor), cancels both from mic
    var clean: [FRAME_SIZE]i16 = undefined;
    state.echo.cancellation(input.ptr, output.ptr, &clean);

    // 4. NS on clean
    _ = state.pp.run(&clean);

    // 5. Save clean for next frame's monitor
    @memcpy(&state.prev_clean, &clean);

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
    state.total_frames += 1;

    if (state.frame_count >= 50) {
        const n_s: f64 = @floatFromInt(state.frame_count * FRAME_SIZE);
        const mic_rms = @sqrt(state.mic_energy_acc / n_s);
        const clean_rms = @sqrt(state.clean_energy_acc / n_s);
        const erle = if (clean_rms > 1.0) 20.0 * std.math.log10(mic_rms / clean_rms) else 60.0;
        const tts_active = state.tts_pos + FRAME_SIZE <= state.tts_data.len;
        std.debug.print("[conv] ERLE={d:.1}dB  mic={d:.0} clean={d:.0} {s}\n", .{
            erle, mic_rms, clean_rms,
            if (tts_active) "▶ TTS" else "■ silent (speak now!)",
        });
        state.mic_energy_acc = 0;
        state.clean_energy_acc = 0;
        state.frame_count = 0;
    }

    return .Continue;
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

    std.debug.print("\n=== Step 6: Real-time Conversation ===\n", .{});
    std.debug.print("TTS plays in background (looping). Speak into mic.\n", .{});
    std.debug.print("You should hear yourself but NOT the TTS echo.\n", .{});
    std.debug.print("Monitor gain: {d:.1}, Duration: {d}s\n\n", .{ MONITOR_GAIN, DURATION_S });

    const tts_data = try loadWav("/tmp/tts_ref.wav", allocator);
    defer allocator.free(tts_data);
    std.debug.print("TTS: {d} samples ({d:.1}s)\n", .{ tts_data.len, @as(f64, @floatFromInt(tts_data.len)) / 16000.0 });

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

    var state = State{ .echo = &echo, .pp = &pp, .tts_data = tts_data };

    var stream: pa.DuplexStream(i16) = undefined;
    try stream.init(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE }, callback, &state);
    defer stream.close();

    try stream.start();
    std.debug.print("[conv] Running... speak now!\n\n", .{});

    std.Thread.sleep(@as(u64, DURATION_S) * std.time.ns_per_s);
    stream.stop() catch {};

    std.debug.print("\n[conv] Done. {d} frames processed.\n\n", .{state.total_frames});
}
