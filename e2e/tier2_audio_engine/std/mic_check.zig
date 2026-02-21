//! Step 1: Mic sanity check — record 3 seconds, save WAV, verify audio quality
//!
//! No speaker output. Just mic capture at 16kHz and 48kHz to compare.

const std = @import("std");
const pa = @import("portaudio");

const DURATION_S: u32 = 3;

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

fn recordAt(sample_rate: u32, allocator: std.mem.Allocator) ![]i16 {
    const total = sample_rate * DURATION_S;
    const frame_size: u32 = @min(sample_rate / 100, 480); // 10ms

    var stream = try pa.InputStream(i16).open(.{
        .sample_rate = @floatFromInt(sample_rate),
        .channels = 1,
        .frames_per_buffer = frame_size,
    });
    defer stream.close();
    try stream.start();

    const buf = try allocator.alloc(i16, total);
    var pos: usize = 0;
    var frame: [480]i16 = undefined;

    while (pos < total) {
        const chunk = @min(frame_size, @as(u32, @intCast(total - pos)));
        try stream.read(frame[0..chunk]);
        @memcpy(buf[pos..][0..chunk], frame[0..chunk]);
        pos += chunk;
    }

    stream.stop() catch {};
    return buf;
}

fn analyzeAndPrint(label: []const u8, samples: []const i16, sample_rate: u32) void {
    var sum_sq: f64 = 0;
    var peak: i16 = 0;
    var zero_count: usize = 0;
    for (samples) |s| {
        const v: f64 = @floatFromInt(s);
        sum_sq += v * v;
        const abs: i16 = if (s < 0) -s else s;
        if (abs > peak) peak = abs;
        if (abs < 5) zero_count += 1;
    }
    const rms = @sqrt(sum_sq / @as(f64, @floatFromInt(samples.len)));
    const db = if (rms > 1.0) 20.0 * @log10(rms / 32768.0) else -100.0;

    std.debug.print("{s} ({d}Hz, {d} samples, {d}ms):\n", .{
        label, sample_rate, samples.len, samples.len * 1000 / sample_rate,
    });
    std.debug.print("  RMS={d:.1} ({d:.1}dBFS), peak={d}, near-zero={d:.1}%\n", .{
        rms, db, peak, @as(f64, @floatFromInt(zero_count)) / @as(f64, @floatFromInt(samples.len)) * 100.0,
    });

    // Check first/last 100ms
    const chunk = sample_rate / 10;
    var rms_start: f64 = 0;
    for (samples[0..chunk]) |s| {
        const v: f64 = @floatFromInt(s);
        rms_start += v * v;
    }
    rms_start = @sqrt(rms_start / @as(f64, @floatFromInt(chunk)));

    var rms_end: f64 = 0;
    const end_start = samples.len - chunk;
    for (samples[end_start..]) |s| {
        const v: f64 = @floatFromInt(s);
        rms_end += v * v;
    }
    rms_end = @sqrt(rms_end / @as(f64, @floatFromInt(chunk)));

    std.debug.print("  first_100ms_rms={d:.1}, last_100ms_rms={d:.1}\n\n", .{ rms_start, rms_end });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Step 1: Mic Sanity Check ===\n", .{});
    std.debug.print("Recording {d}s at 16kHz and 48kHz. Stay quiet.\n\n", .{DURATION_S});

    try pa.init();
    defer pa.deinit();

    if (pa.deviceInfo(pa.defaultInputDevice())) |info| {
        std.debug.print("Input device: {s} (native rate: {d:.0}Hz)\n\n", .{
            info.name, info.default_sample_rate,
        });
    }

    // Record at 16kHz
    std.debug.print("Recording at 16kHz...\n", .{});
    const rec_16k = try recordAt(16000, allocator);
    defer allocator.free(rec_16k);

    // Record at 48kHz
    std.debug.print("Recording at 48kHz...\n", .{});
    const rec_48k = try recordAt(48000, allocator);
    defer allocator.free(rec_48k);

    // Analyze
    analyzeAndPrint("16kHz recording", rec_16k, 16000);
    analyzeAndPrint("48kHz recording", rec_48k, 48000);

    // Save
    try writeWav("/tmp/mic_check_16k.wav", rec_16k, 16000);
    try writeWav("/tmp/mic_check_48k.wav", rec_48k, 48000);

    std.debug.print("Saved:\n  /tmp/mic_check_16k.wav\n  /tmp/mic_check_48k.wav\n\n", .{});

    // Verdict
    const rms_16k = blk: {
        var s: f64 = 0;
        for (rec_16k) |v| {
            const f: f64 = @floatFromInt(v);
            s += f * f;
        }
        break :blk @sqrt(s / @as(f64, @floatFromInt(rec_16k.len)));
    };
    const rms_48k = blk: {
        var s: f64 = 0;
        for (rec_48k) |v| {
            const f: f64 = @floatFromInt(v);
            s += f * f;
        }
        break :blk @sqrt(s / @as(f64, @floatFromInt(rec_48k.len)));
    };

    if (rms_16k > 500 and rms_48k > 500) {
        std.debug.print("VERDICT: Both recordings have signal. Mic works.\n", .{});
    } else if (rms_48k > 500 and rms_16k < 100) {
        std.debug.print("VERDICT: 48kHz works, 16kHz is dead. Use 48kHz + resample.\n", .{});
    } else if (rms_16k < 100 and rms_48k < 100) {
        std.debug.print("VERDICT: Both silent. Check mic permissions (System Settings > Privacy).\n", .{});
    } else {
        std.debug.print("VERDICT: 16kHz rms={d:.1}, 48kHz rms={d:.1}. Investigate.\n", .{ rms_16k, rms_48k });
    }
    std.debug.print("\n", .{});
}
