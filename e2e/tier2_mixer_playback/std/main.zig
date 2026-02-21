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

    // Reader: mixer.read() → speaker.write(), with timing diagnostics
    var frame: [160]i16 = undefined;
    var total_written: usize = 0;
    const expected_frame_us: i64 = @intCast(@as(u64, 160) * 1_000_000 / SAMPLE_RATE); // 10000us
    var last_write_ts: i64 = std.time.microTimestamp();
    var max_mixer_us: i64 = 0;
    var max_write_us: i64 = 0;
    var max_gap_us: i64 = 0;
    var glitch_count: u32 = 0;

    std.debug.print("Playing (frame={d}us)...\n", .{expected_frame_us});
    while (total_written < total_samples) {
        const ts0 = std.time.microTimestamp();
        const n = mx.read(&frame) orelse break;
        const ts1 = std.time.microTimestamp();
        try speaker.write(frame[0..n]);
        const ts2 = std.time.microTimestamp();

        const mixer_us = ts1 - ts0;
        const write_us = ts2 - ts1;
        const gap_us = ts0 - last_write_ts;

        if (mixer_us > max_mixer_us) max_mixer_us = mixer_us;
        if (write_us > max_write_us) max_write_us = write_us;
        if (gap_us > max_gap_us) max_gap_us = gap_us;

        // Flag glitches: gap between end-of-last-write and start-of-this-mixer > 2x frame
        if (total_written > 0 and gap_us > expected_frame_us * 2) {
            glitch_count += 1;
            if (glitch_count <= 10) {
                std.debug.print("  GLITCH @{d}ms: gap={d}us mixer={d}us write={d}us\n", .{
                    total_written * 1000 / SAMPLE_RATE,
                    gap_us,
                    mixer_us,
                    write_us,
                });
            }
        }

        last_write_ts = ts2;
        total_written += n;

        if (total_written % (SAMPLE_RATE) == 0) {
            std.debug.print("  [{d}s] max: mixer={d}us write={d}us gap={d}us glitches={d}\n", .{
                total_written / SAMPLE_RATE,
                max_mixer_us,
                max_write_us,
                max_gap_us,
                glitch_count,
            });
            max_mixer_us = 0;
            max_write_us = 0;
            max_gap_us = 0;
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
