const std = @import("std");
const wav = @import("wav_reader");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get filename from args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: quick_analyze <file.wav>\n", .{});
        return;
    }

    const filename = args[1];
    var w = try wav.WavReader.init(filename);
    defer w.deinit();

    std.debug.print("\n=== {s} ===\n", .{filename});
    std.debug.print("Samples: {d}, SampleRate: {d}Hz\n\n", .{w.num_samples, w.sample_rate});

    var buf: [160]i16 = undefined;
    var frame: usize = 0;

    std.debug.print("Frame RMS analysis (first 50 frames = 0.5s):\n", .{});
    std.debug.print("{s:>5} {s:>8} {s:>8} {s}\n", .{"frame", "rms", "max", "level"});
    std.debug.print("{s}\n", .{"-" ** 35});

    while (frame < 50) {
        const n = try w.readSamples(&buf);
        if (n < 160) break;

        var energy: f64 = 0;
        var max_val: i16 = 0;
        for (buf) |s| {
            const v: f64 = @floatFromInt(s);
            energy += v * v;
            if (@abs(s) > max_val) max_val = @intCast(@abs(s));
        }
        const rms = @sqrt(energy / 160.0);

        const level = if (rms < 200) "quiet"
            else if (rms < 1000) "normal"
            else if (rms < 5000) "loud"
            else "VERY LOUD";

        std.debug.print("{d:>5} {d:>8.0} {d:>8} {s}\n", .{frame, rms, max_val, level});
        frame += 1;
    }
    std.debug.print("\n", .{});
}
