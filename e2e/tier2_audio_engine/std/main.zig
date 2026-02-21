//! Audio Engine Live Test (E2E-11) — full-duplex sweep + AEC + mic monitor
//!
//! Uses PortAudio full-duplex callback: one stream handles both mic input
//! and speaker output simultaneously. No timing mismatch, no glitches.
//!
//! The callback does everything in one shot:
//!   1. Generate sweep → fill output buffer
//!   2. Read mic from input buffer
//!   3. AEC cancel sweep echo from mic
//!   4. Mix clean audio into output (monitor)
//!   5. Accumulate ERLE
//!
//! Run: cd e2e/tier2_audio_engine/std && zig build run

const std = @import("std");
const pa = @import("portaudio");
const audio_pkg = @import("audio");
const speexdsp = @import("speexdsp");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const RUN_SECONDS: u32 = 15;
const SWEEP_AMP: f64 = 3000.0;

const State = struct {
    echo: speexdsp.EchoState,
    pp: speexdsp.Preprocess,
    sweep_idx: usize = 0,
    clean_accum: f64 = 0,
    frame_count: u32 = 0,
};

fn audioCallback(
    input: []const i16,
    output: []i16,
    frames: usize,
    user_data: ?*anyopaque,
) pa.CallbackResult {
    const state: *State = @ptrCast(@alignCast(user_data));
    _ = frames;

    // 1. Generate sweep → output buffer (ref signal for AEC)
    const f_start: f64 = 20.0;
    const f_end: f64 = 8000.0;
    const sr: f64 = @floatFromInt(SAMPLE_RATE);
    const sweep_dur: f64 = 10.0;

    for (output, 0..) |*s, i| {
        const t: f64 = @as(f64, @floatFromInt(state.sweep_idx + i)) / sr;
        const progress = @mod(t, sweep_dur) / sweep_dur;
        const freq = f_start + (f_end - f_start) * progress;
        const phase = 2.0 * std.math.pi * freq * t;
        s.* = @intFromFloat(@sin(phase) * SWEEP_AMP);
    }

    // 2. AEC: cancel sweep echo from mic input
    var clean: [4096]i16 = undefined;
    state.echo.cancellation(input.ptr, output.ptr, &clean);

    // 3. NS on clean audio
    _ = state.pp.run(&clean);

    // 4. Mix clean audio into output (so you hear yourself + sweep)
    for (output, 0..) |*s, i| {
        const mixed: i32 = @as(i32, s.*) + @as(i32, clean[i]);
        s.* = @intCast(std.math.clamp(mixed, -32768, 32767));
    }

    // 5. Accumulate ERLE
    for (clean[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.clean_accum += v * v;
    }
    state.frame_count += 1;
    state.sweep_idx += output.len;

    if (state.frame_count >= 50) {
        const clean_rms = @sqrt(state.clean_accum / @as(f64, @floatFromInt(state.frame_count * FRAME_SIZE)));
        const ref_rms: f64 = SWEEP_AMP / @sqrt(2.0);
        const erle = if (clean_rms > 1.0)
            20.0 * std.math.log10(ref_rms / clean_rms)
        else
            60.0;

        std.debug.print("[live] ERLE={d:.1}dB  (ref={d:.0}, clean={d:.0})\n", .{
            erle, ref_rms, clean_rms,
        });
        state.clean_accum = 0;
        state.frame_count = 0;
    }

    return .Continue;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Audio Engine Live Test (E2E-11) ===\n", .{});
    std.debug.print("Full-duplex: sweep + AEC + mic monitor\n", .{});
    std.debug.print("Speak into mic — you should hear yourself, NOT the sweep\n", .{});
    std.debug.print("Duration: {d}s\n\n", .{RUN_SECONDS});

    try pa.init();
    defer pa.deinit();

    std.debug.print("PortAudio: {s}\n", .{pa.versionText()});
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| {
        std.debug.print("Input:  {s}\n", .{info.name});
    }
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| {
        std.debug.print("Output: {s}\n", .{info.name});
    }
    std.debug.print("\n", .{});

    // Init SpeexDSP AEC + NS
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

    var state = State{
        .echo = echo,
        .pp = pp,
    };

    // Open full-duplex stream
    var stream: pa.DuplexStream(i16) = undefined;
    try stream.init(.{
        .sample_rate = SAMPLE_RATE,
        .channels = 1,
        .frames_per_buffer = FRAME_SIZE,
    }, audioCallback, &state);
    defer stream.close();

    try stream.start();

    std.debug.print("[live] Running for {d}s...\n\n", .{RUN_SECONDS});

    var elapsed: u32 = 0;
    while (elapsed < RUN_SECONDS) {
        std.Thread.sleep(1 * std.time.ns_per_s);
        elapsed += 1;
    }

    stream.stop() catch {};
    std.debug.print("\n[live] Done.\n\n", .{});
}
