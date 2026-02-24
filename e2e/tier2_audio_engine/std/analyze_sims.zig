const std = @import("std");

fn analyzeWav(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header: [44]u8 = undefined;
    _ = try file.read(&header);

    const stat = try file.stat();
    const num_samples = (stat.size - 44) / 2;

    var buf: [160]i16 = undefined;
    var total_rms: f64 = 0;
    const num_frames = num_samples / 160;

    for (0..num_frames) |_| {
        const bytes = try file.read(std.mem.sliceAsBytes(&buf));
        if (bytes < 320) break;

        var frame_energy: f64 = 0;
        for (buf) |s| {
            const v: f64 = @floatFromInt(s);
            frame_energy += v * v;
        }
        total_rms += frame_energy;
    }

    const avg_rms = @sqrt(total_rms / @as(f64, @floatFromInt(num_samples * 160)));
    std.debug.print("{s:25} | RMS: {d:10.1} | samples: {d}\n", .{ path, avg_rms, num_samples });
}

pub fn main() !void {
    std.debug.print("=== Audio Comparison ===\n\n", .{});
    try analyzeWav("/tmp/tts_input.wav"); // 原始 TTS
    try analyzeWav("/tmp/e1_sim_ref.wav"); // SimAudio ref (speaker output)
    try analyzeWav("/tmp/e1_sim_mic.wav"); // mic input
    try analyzeWav("/tmp/e1_sim_clean.wav"); // AEC output
}
