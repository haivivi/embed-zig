//! T5: 60s stability test — 440Hz + AEC3
//! Verifies ERLE doesn't degrade over 60 seconds.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");
const Aec3 = audio.aec3.aec3.Aec3;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 60;
const TOTAL_SAMPLES = SAMPLE_RATE * DURATION_S;

const State = struct {
    aec: *Aec3,
    phase_idx: usize = 0,
    pos: usize = 0,
    mic_energy_acc: f64 = 0,
    clean_energy_acc: f64 = 0,
    frame_count: u32 = 0,
    first_erle: f32 = 0,
    last_erle: f32 = 0,
    min_erle: f32 = 100,
    report_count: u32 = 0,
};

fn callback(input: []const i16, output: []i16, _: usize, user_data: ?*anyopaque) pa.CallbackResult {
    const state: *State = @ptrCast(@alignCast(user_data));

    for (output, 0..) |*s, i| {
        const t: f64 = @as(f64, @floatFromInt(state.phase_idx + i)) / @as(f64, @floatFromInt(SAMPLE_RATE));
        s.* = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 10000.0);
    }

    var clean: [FRAME_SIZE]i16 = undefined;
    state.aec.process(input, output, &clean);

    for (input[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.mic_energy_acc += v * v;
    }
    for (clean) |s| {
        const v: f64 = @floatFromInt(s);
        state.clean_energy_acc += v * v;
    }
    state.frame_count += 1;
    state.phase_idx += output.len;
    state.pos += output.len;

    if (state.frame_count >= 100) {
        const n: f64 = @floatFromInt(state.frame_count * FRAME_SIZE);
        const mic_rms = @sqrt(state.mic_energy_acc / n);
        const clean_rms = @sqrt(state.clean_energy_acc / n);
        const erle: f32 = if (clean_rms > 1.0) @floatCast(20.0 * std.math.log10(mic_rms / clean_rms)) else 60.0;

        state.report_count += 1;
        state.last_erle = erle;
        if (state.report_count == 1) state.first_erle = erle;
        if (erle < state.min_erle) state.min_erle = erle;

        if (state.report_count % 10 == 0) {
            std.debug.print("  [{d}s] ERLE={d:.1}dB  mic={d:.0} clean={d:.0}\n", .{
                state.pos / SAMPLE_RATE, erle, mic_rms, clean_rms,
            });
        }
        state.mic_energy_acc = 0;
        state.clean_energy_acc = 0;
        state.frame_count = 0;
    }

    if (state.pos >= TOTAL_SAMPLES) return .Complete;
    return .Continue;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== T5: 60s Stability — 440Hz + AEC3 ===\n\n", .{});

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var aec = try Aec3.init(allocator, .{ .frame_size = FRAME_SIZE, .num_partitions = 50 });
    defer aec.deinit();

    var state = State{ .aec = &aec };

    var stream: pa.DuplexStream(i16) = undefined;
    try stream.init(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE }, callback, &state);
    defer stream.close();

    try stream.start();
    std.debug.print("Running 60s (printing every 5s)...\n\n", .{});

    while (state.pos < TOTAL_SAMPLES) std.Thread.sleep(1 * std.time.ns_per_s);
    std.Thread.sleep(500 * std.time.ns_per_ms);
    stream.stop() catch {};

    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("First ERLE: {d:.1}dB\n", .{state.first_erle});
    std.debug.print("Last ERLE:  {d:.1}dB\n", .{state.last_erle});
    std.debug.print("Min ERLE:   {d:.1}dB\n", .{state.min_erle});

    const stable = state.last_erle >= state.first_erle * 0.8;
    std.debug.print("VERDICT: {s}\n\n", .{if (stable) "PASS — stable" else "FAIL — degraded"});
}
