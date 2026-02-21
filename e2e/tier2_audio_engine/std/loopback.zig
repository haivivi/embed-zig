//! Mic → AEC3 → Speaker loopback
//!
//! Speaker output = clean audio from AEC3 (your voice, echo cancelled).
//! ref = actual speaker output (previous frame's clean * gain).
//! AEC3 cancels speaker echo from mic, you should hear yourself clearly
//! without echo buildup.
//!
//! Duration: 20s.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");
const Aec3 = audio.aec3.aec3.Aec3;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 20;
const MONITOR_GAIN: f32 = 0.5;

const State = struct {
    aec: *Aec3,
    prev_clean: [FRAME_SIZE]i16 = [_]i16{0} ** FRAME_SIZE,
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

    // Output = previous frame's clean audio * gain
    // This IS the ref signal for AEC (what actually goes to speaker)
    for (output, 0..) |*s, i| {
        s.* = @intFromFloat(@as(f32, @floatFromInt(state.prev_clean[i])) * MONITOR_GAIN);
    }

    // AEC3: cancel speaker echo from mic, ref = output (actual speaker signal)
    var clean: [FRAME_SIZE]i16 = undefined;
    state.aec.process(input, output, &clean);

    // Save for next frame
    @memcpy(&state.prev_clean, &clean);

    // ERLE measurement
    for (input[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.mic_energy_acc += v * v;
    }
    for (clean) |s| {
        const v: f64 = @floatFromInt(s);
        state.clean_energy_acc += v * v;
    }
    state.frame_count += 1;

    if (state.frame_count >= 100) {
        const n: f64 = @floatFromInt(state.frame_count * FRAME_SIZE);
        const mic_rms = @sqrt(state.mic_energy_acc / n);
        const clean_rms = @sqrt(state.clean_energy_acc / n);
        const erle = if (clean_rms > 1.0) 20.0 * std.math.log10(mic_rms / clean_rms) else 60.0;
        std.debug.print("  ERLE={d:.1}dB  mic={d:.0} clean={d:.0}\n", .{ erle, mic_rms, clean_rms });
        state.mic_energy_acc = 0;
        state.clean_energy_acc = 0;
        state.frame_count = 0;
    }

    return .Continue;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Mic → AEC3 → Speaker ===\n", .{});
    std.debug.print("Speak into mic. You should hear yourself WITHOUT echo.\n", .{});
    std.debug.print("Monitor gain={d:.1}, Duration={d}s\n\n", .{ MONITOR_GAIN, DURATION_S });

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var aec = try Aec3.init(allocator, .{ .frame_size = FRAME_SIZE, .num_partitions = 50 });
    defer aec.deinit();

    var state = State{ .aec = &aec };

    var stream: pa.DuplexStream(i16) = undefined;
    try stream.init(.{
        .sample_rate = SAMPLE_RATE,
        .channels = 1,
        .frames_per_buffer = FRAME_SIZE,
    }, callback, &state);
    defer stream.close();

    try stream.start();
    std.debug.print("Running... speak now!\n\n", .{});
    std.Thread.sleep(@as(u64, DURATION_S) * std.time.ns_per_s);
    stream.stop() catch {};
    std.debug.print("\nDone.\n\n", .{});
}
