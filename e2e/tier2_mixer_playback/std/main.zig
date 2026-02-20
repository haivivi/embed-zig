//! Mixer Playback E2E Test — 3-track chord through PortAudio speaker
//!
//! Plays three simultaneous sine waves (440Hz + 660Hz + 880Hz = A major chord)
//! through the system speaker via PortAudio. You should hear the chord for 3 seconds.
//!
//! Run: cd e2e/tier2_mixer_playback/std && zig build run

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const Rt = @import("std_impl").runtime;
const Mixer = audio.mixer.Mixer(Rt);
const Format = audio.resampler.Format;

const SAMPLE_RATE: u32 = 16000;
const DURATION_SEC: u32 = 3;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Mixer Playback E2E Test ===\n", .{});
    std.debug.print("Playing A major chord (440 + 660 + 880 Hz) for {d}s\n\n", .{DURATION_SEC});

    try pa.init();
    defer pa.deinit();

    std.debug.print("PortAudio: {s}\n", .{pa.versionText()});
    const out_dev = pa.defaultOutputDevice();
    if (pa.deviceInfo(out_dev)) |info| {
        std.debug.print("Output: {s}\n\n", .{info.name});
    }

    // Open speaker
    var speaker = try pa.OutputStream(i16).open(.{
        .sample_rate = SAMPLE_RATE,
        .channels = 1,
        .frames_per_buffer = 160,
    });
    defer speaker.close();
    try speaker.start();

    // Create mixer
    var mx = Mixer.init(allocator, .{
        .output = .{ .rate = SAMPLE_RATE, .channels = .mono },
    });
    defer mx.deinit();

    const format = Format{ .rate = SAMPLE_RATE, .channels = .mono };
    const total_samples = SAMPLE_RATE * DURATION_SEC;

    // Generate tones
    const tone440 = try allocator.alloc(i16, total_samples);
    defer allocator.free(tone440);
    const tone660 = try allocator.alloc(i16, total_samples);
    defer allocator.free(tone660);
    const tone880 = try allocator.alloc(i16, total_samples);
    defer allocator.free(tone880);

    for (tone440, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
        s.* = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 8000.0);
    }
    for (tone660, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
        s.* = @intFromFloat(@sin(t * 660.0 * 2.0 * std.math.pi) * 8000.0);
    }
    for (tone880, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
        s.* = @intFromFloat(@sin(t * 880.0 * 2.0 * std.math.pi) * 8000.0);
    }

    // Create 3 tracks and write data
    const h1 = try mx.createTrack(.{ .label = "440Hz" });
    const h2 = try mx.createTrack(.{ .label = "660Hz" });
    const h3 = try mx.createTrack(.{ .label = "880Hz" });

    // Writer threads
    const Writer = struct {
        fn run(track: *Mixer.Track, fmt: Format, data: []const i16) void {
            track.write(fmt, data) catch {};
        }
    };
    const t1 = try std.Thread.spawn(.{}, Writer.run, .{ h1.track, format, tone440 });
    const t2 = try std.Thread.spawn(.{}, Writer.run, .{ h2.track, format, tone660 });
    const t3 = try std.Thread.spawn(.{}, Writer.run, .{ h3.track, format, tone880 });

    // Reader: mixer.read() → speaker.write()
    var frame: [160]i16 = undefined;
    var total_written: usize = 0;

    std.debug.print("Playing...", .{});
    while (total_written < total_samples) {
        const n = mx.read(&frame) orelse break;
        try speaker.write(frame[0..n]);
        total_written += n;

        // Progress dots
        if (total_written % (SAMPLE_RATE) == 0) {
            std.debug.print(".", .{});
        }
    }

    t1.join();
    t2.join();
    t3.join();
    h1.ctrl.closeWrite();
    h2.ctrl.closeWrite();
    h3.ctrl.closeWrite();

    speaker.stop() catch {};

    std.debug.print("\n\nDone! Played {d} samples ({d}ms)\n", .{
        total_written, total_written * 1000 / SAMPLE_RATE,
    });
    std.debug.print("PASS if you heard a chord.\n\n", .{});
}
