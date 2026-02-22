//! Diagnostic: record mic only, no speaker output, no AEC.
//! Just capture what the mic hears in a quiet room and save to WAV.

const std = @import("std");
const pa = @import("portaudio");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 5;

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
    std.debug.print("\n=== Mic Only — recording quiet room ===\n", .{});
    std.debug.print("No speaker output. Just recording mic for {d}s.\n\n", .{DURATION_S});

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input: {s}\n\n", .{info.name});

    var stream = try pa.InputStream(i16).open(.{
        .sample_rate = @floatFromInt(SAMPLE_RATE),
        .channels = 1,
        .frames_per_buffer = FRAME_SIZE,
    });
    try stream.start();
    defer {
        stream.stop() catch {};
        stream.close();
    }

    const total = SAMPLE_RATE * DURATION_S;
    var buf: [total]i16 = undefined;
    var pos: usize = 0;

    while (pos < total) {
        var frame: [FRAME_SIZE]i16 = undefined;
        try stream.read(&frame);

        const remaining = total - pos;
        const n = @min(FRAME_SIZE, remaining);
        @memcpy(buf[pos..][0..n], frame[0..n]);
        pos += n;
    }

    // Per-second RMS
    for (0..DURATION_S) |s| {
        const start = s * SAMPLE_RATE;
        const end = start + SAMPLE_RATE;
        var energy: f64 = 0;
        for (buf[start..end]) |sample| {
            const v: f64 = @floatFromInt(sample);
            energy += v * v;
        }
        const rms = @sqrt(energy / @as(f64, SAMPLE_RATE));
        std.debug.print("[{d}s] rms={d:.1}\n", .{ s + 1, rms });
    }

    try writeWav("/tmp/mic_only.wav", buf[0..pos]);
    std.debug.print("\nSaved: /tmp/mic_only.wav ({d} samples)\n\n", .{pos});
}
