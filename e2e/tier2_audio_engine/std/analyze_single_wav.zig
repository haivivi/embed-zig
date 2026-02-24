//! Analyze a single WAV file for noise level
const std = @import("std");
const wav = @import("wav_reader");

const SAMPLE_RATE = 16000;
const FRAME_SIZE = 160;

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // skip program name
    const filename = args.next() orelse {
        std.debug.print("Usage: analyze_single_wav <filename.wav>\n", .{});
        return;
    };

    var w = try wav.WavReader.init(filename);

    std.debug.print("\n=== Analyzing: {s} ===\n", .{filename});
    std.debug.print("Total samples: {d}\n\n", .{w.num_samples});

    var buf: [FRAME_SIZE]i16 = undefined;
    var frame_count: usize = 0;

    std.debug.print("Frame-by-frame RMS (first 100 frames):\n", .{});
    std.debug.print("{s:>5} {s:>10} {s:>10} {s}\n", .{"frame", "rms", "max", "status"});
    std.debug.print("{s}\n", .{"-" ** 40});

    while (frame_count < 100) {
        const n = try w.readSamples(&buf);
        if (n < FRAME_SIZE) break;

        var energy: f64 = 0;
        var max_val: i16 = 0;

        for (0..FRAME_SIZE) |i| {
            const v: f64 = @floatFromInt(buf[i]);
            energy += v * v;
            if (@abs(buf[i]) > max_val) max_val = @intCast(@abs(buf[i]));
        }

        const rms = @sqrt(energy / FRAME_SIZE);

        const status = if (rms < 200)
            "quiet"
        else if (rms < 1000)
            "normal"
        else if (rms < 5000)
            "loud"
        else
            "VERY LOUD (feedback?)";

        std.debug.print("{d:>5} {d:>10.0} {d:>10} {s}\n", .{
            frame_count, rms, max_val, status,
        });

        frame_count += 1;
    }

    w.deinit();
    std.debug.print("\n", .{});
}
