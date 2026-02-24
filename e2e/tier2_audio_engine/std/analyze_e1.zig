const std = @import("std");

const FRAME_SIZE: usize = 160;

fn analyzeWav(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header: [44]u8 = undefined;
    _ = try file.read(&header);

    const stat = try file.stat();
    const num_samples = (stat.size - 44) / 2;
    const num_frames = num_samples / FRAME_SIZE;

    var buf: [FRAME_SIZE]i16 = undefined;
    var total_rms: f64 = 0;
    var max_sample: i16 = 0;

    for (0..num_frames) |_| {
        const bytes = try file.read(std.mem.sliceAsBytes(&buf));
        if (bytes < FRAME_SIZE * 2) break;

        var frame_energy: f64 = 0;
        for (buf) |s| {
            const v: f64 = @floatFromInt(s);
            frame_energy += v * v;
            if (@abs(s) > max_sample) max_sample = s;
        }
        total_rms += frame_energy;
    }

    const avg_rms = @sqrt(total_rms / @as(f64, @floatFromInt(num_samples)));
    std.debug.print("{s:20} | RMS: {d:10.1} | Max: {d}\n", .{ path, avg_rms, max_sample });
}

pub fn main() !void {
    std.debug.print("\n=== E1 Test Results ===\n\n", .{});

    try analyzeWav("e1_mic.wav");
    try analyzeWav("e1_ref.wav");
    try analyzeWav("e1_clean.wav");

    std.debug.print("\n", .{});
    std.debug.print("Analysis:\n", .{});
    std.debug.print("- If AEC works: clean_rms should be significantly lower than mic_rms\n", .{});
    std.debug.print("- ref_rms shows how much echo is being captured\n", .{});
}
