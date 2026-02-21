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

const MAX_RECORD_SAMPLES = SAMPLE_RATE * RUN_SECONDS;

const State = struct {
    echo: speexdsp.EchoState,
    pp: speexdsp.Preprocess,
    sweep_idx: usize = 0,
    clean_accum: f64 = 0,
    frame_count: u32 = 0,
    // Recording buffers
    output_record: []i16,
    mic_record: []i16,
    clean_record: []i16,
    record_pos: usize = 0,
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

    // 4b. Record to buffers
    if (state.record_pos + output.len <= state.output_record.len) {
        @memcpy(state.output_record[state.record_pos..][0..output.len], output);
        @memcpy(state.mic_record[state.record_pos..][0..input.len], input);
        @memcpy(state.clean_record[state.record_pos..][0..output.len], clean[0..output.len]);
        state.record_pos += output.len;
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

fn writeWav(path: []const u8, samples: []const i16, sample_rate: u32) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const num_channels: u16 = 1;
    const bits_per_sample: u16 = 16;
    const byte_rate: u32 = sample_rate * @as(u32, num_channels) * @as(u32, bits_per_sample) / 8;
    const block_align: u16 = num_channels * bits_per_sample / 8;
    const data_size: u32 = @intCast(samples.len * 2);

    // Build header in a buffer
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], 36 + data_size, .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, hdr[22..24], num_channels, .little);
    std.mem.writeInt(u32, hdr[24..28], sample_rate, .little);
    std.mem.writeInt(u32, hdr[28..32], byte_rate, .little);
    std.mem.writeInt(u16, hdr[32..34], block_align, .little);
    std.mem.writeInt(u16, hdr[34..36], bits_per_sample, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_size, .little);

    try file.writeAll(&hdr);
    try file.writeAll(std.mem.sliceAsBytes(samples));
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

    const output_rec = try allocator.alloc(i16, MAX_RECORD_SAMPLES);
    defer allocator.free(output_rec);
    const mic_rec = try allocator.alloc(i16, MAX_RECORD_SAMPLES);
    defer allocator.free(mic_rec);
    const clean_rec = try allocator.alloc(i16, MAX_RECORD_SAMPLES);
    defer allocator.free(clean_rec);

    var state = State{
        .echo = echo,
        .pp = pp,
        .output_record = output_rec,
        .mic_record = mic_rec,
        .clean_record = clean_rec,
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

    const recorded = state.record_pos;
    std.debug.print("\n[live] Recorded {d} samples ({d}ms)\n", .{
        recorded, recorded * 1000 / SAMPLE_RATE,
    });

    // Write WAV files
    const out_path = "/tmp/aec_speaker_output.wav";
    const mic_path = "/tmp/aec_mic_input.wav";
    const clean_path = "/tmp/aec_clean.wav";

    writeWav(out_path, state.output_record[0..recorded], SAMPLE_RATE) catch |e| {
        std.debug.print("Failed to write {s}: {}\n", .{ out_path, e });
    };
    writeWav(mic_path, state.mic_record[0..recorded], SAMPLE_RATE) catch |e| {
        std.debug.print("Failed to write {s}: {}\n", .{ mic_path, e });
    };
    writeWav(clean_path, state.clean_record[0..recorded], SAMPLE_RATE) catch |e| {
        std.debug.print("Failed to write {s}: {}\n", .{ clean_path, e });
    };

    std.debug.print("\nSaved:\n  {s}\n  {s}\n  {s}\n", .{ out_path, mic_path, clean_path });
    std.debug.print("\n[live] Done.\n\n", .{});
}
