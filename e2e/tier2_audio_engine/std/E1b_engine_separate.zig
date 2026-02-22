//! E1b: Real-time conversation loopback (Separate streams + buffer_depth)
//!
//! Same as E1 but uses independent PortAudio InputStream/OutputStream
//! with speaker_buffer_depth=5 for ref alignment compensation.
//!
//! user speaks → mic → AEC → clean → track → mixer → speaker

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const std_impl = @import("std_impl");
const Rt = std_impl.runtime;
const MicDriver = std_impl.mic.Driver;
const SpeakerDriver = std_impl.speaker.Driver;
const Mixer = audio.mixer.Mixer(Rt);
const Format = audio.resampler.Format;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 30;
const BUFFER_DEPTH: u32 = 5;

const Engine = audio.engine.AudioEngine(Rt, MicDriver, SpeakerDriver, .{
    .enable_aec = true,
    .enable_ns = true,
    .frame_size = FRAME_SIZE,
    .sample_rate = SAMPLE_RATE,
    .speaker_buffer_depth = BUFFER_DEPTH,
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== E1b: Real-time Loopback (Separate Streams, depth={d}) ===\n", .{BUFFER_DEPTH});
    std.debug.print("Speak into mic → AEC → speaker. Duration: {d}s\n\n", .{DURATION_S});

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var mic_drv = try MicDriver.init(.{ .sample_rate = SAMPLE_RATE, .frames_per_buffer = FRAME_SIZE });
    defer mic_drv.deinit();
    var spk_drv = try SpeakerDriver.init(.{ .sample_rate = SAMPLE_RATE, .frames_per_buffer = FRAME_SIZE });
    defer spk_drv.deinit();

    var engine = try Engine.init(allocator, &mic_drv, &spk_drv, {});
    defer engine.deinit();

    const format = Format{ .rate = SAMPLE_RATE, .channels = .mono };

    const loopback = try engine.createTrack(.{ .label = "loopback" });

    var running = std.atomic.Value(bool).init(true);

    try engine.start();
    std.debug.print(">>> SPEAK NOW! <<<\n\n", .{});

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(eng: *Engine, track: *Mixer.Track, fmt: Format, r: *std.atomic.Value(bool)) void {
            var frame: [160]i16 = undefined;
            while (r.load(.acquire)) {
                const n = eng.readClean(&frame) orelse break;
                if (n == 0) continue;
                track.write(fmt, frame[0..n]) catch break;
            }
        }
    }.run, .{ &engine, loopback.track, format, &running });

    std.Thread.sleep(@as(u64, DURATION_S) * std.time.ns_per_s);

    std.debug.print("\nStopping...\n", .{});
    running.store(false, .release);
    loopback.ctrl.closeWrite();
    engine.stop();
    reader.join();

    std.debug.print("[E1b] Done. No crash.\n\n", .{});
}
