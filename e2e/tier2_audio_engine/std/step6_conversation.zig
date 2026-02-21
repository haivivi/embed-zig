//! Step 6: Conversation — TTS plays once + AEC3 + clean monitor at 0.3 gain
//! ref = actual speaker output (TTS + monitor) to prevent positive feedback.
//! Speaker plays TTS once, then silence. You can speak during silence period.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");
const Aec3 = audio.aec3.aec3.Aec3;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 15;
const MONITOR_GAIN: f32 = 0.3;

const State = struct {
    aec: *Aec3,
    tts_data: []const i16,
    tts_pos: usize = 0,
    prev_clean: [FRAME_SIZE]i16 = [_]i16{0} ** FRAME_SIZE,
    mic_energy_acc: f64 = 0,
    clean_energy_acc: f64 = 0,
    frame_count: u32 = 0,
    total_frames: u32 = 0,
};

fn callback(input: []const i16, output: []i16, _: usize, user_data: ?*anyopaque) pa.CallbackResult {
    const state: *State = @ptrCast(@alignCast(user_data));

    // TTS (once, not looped)
    var tts: [FRAME_SIZE]i16 = undefined;
    if (state.tts_pos + output.len <= state.tts_data.len) {
        @memcpy(&tts, state.tts_data[state.tts_pos..][0..output.len]);
        state.tts_pos += output.len;
    } else {
        @memset(&tts, 0);
    }

    // Output = TTS + prev_clean * gain (ref = actual speaker output)
    for (output, 0..) |*s, i| {
        const t: i32 = tts[i];
        const m: i32 = @intFromFloat(@as(f32, @floatFromInt(state.prev_clean[i])) * MONITOR_GAIN);
        s.* = @intCast(std.math.clamp(t + m, -32768, 32767));
    }

    // AEC3: ref = output (includes monitor), cancels both
    var clean: [FRAME_SIZE]i16 = undefined;
    state.aec.process(input, output, &clean);

    @memcpy(&state.prev_clean, &clean);

    for (input[0..output.len]) |s| {
        const v: f64 = @floatFromInt(s);
        state.mic_energy_acc += v * v;
    }
    for (clean) |s| {
        const v: f64 = @floatFromInt(s);
        state.clean_energy_acc += v * v;
    }
    state.frame_count += 1;
    state.total_frames += 1;

    if (state.frame_count >= 50) {
        const n: f64 = @floatFromInt(state.frame_count * FRAME_SIZE);
        const mic_rms = @sqrt(state.mic_energy_acc / n);
        const clean_rms = @sqrt(state.clean_energy_acc / n);
        const erle = if (clean_rms > 1.0) 20.0 * std.math.log10(mic_rms / clean_rms) else 60.0;
        const tts_active = state.tts_pos + FRAME_SIZE <= state.tts_data.len;
        std.debug.print("  ERLE={d:.1}dB  mic={d:.0} clean={d:.0} {s}\n", .{
            erle, mic_rms, clean_rms,
            if (tts_active) "▶ TTS" else "■ speak now",
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
    const buf = try allocator.alloc(i16, (stat.size - 44) / 2);
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

    std.debug.print("\n=== Step 6: Conversation — TTS + AEC3 + Monitor ===\n", .{});
    std.debug.print("TTS plays once, then silence. Speak during silence.\n", .{});
    std.debug.print("Monitor gain={d:.1}, Duration={d}s\n\n", .{ MONITOR_GAIN, DURATION_S });

    const tts_data = loadWav("/tmp/tts_ref.wav", allocator) catch {
        std.debug.print("ERROR: /tmp/tts_ref.wav not found.\n", .{});
        return;
    };
    defer allocator.free(tts_data);

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var aec = try Aec3.init(allocator, .{ .frame_size = FRAME_SIZE, .num_partitions = 50 });
    defer aec.deinit();

    var state = State{ .aec = &aec, .tts_data = tts_data };

    var stream: pa.DuplexStream(i16) = undefined;
    try stream.init(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE }, callback, &state);
    defer stream.close();

    try stream.start();
    std.debug.print("Running...\n\n", .{});
    std.Thread.sleep(@as(u64, DURATION_S) * std.time.ns_per_s);
    stream.stop() catch {};

    std.debug.print("\nDone. {d} frames.\n\n", .{state.total_frames});
}
