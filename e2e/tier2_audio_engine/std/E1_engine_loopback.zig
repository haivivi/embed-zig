//! E1: AudioEngine basic loopback — mic → AEC → mixer → speaker
//!
//! Engine runs, no TTS. You speak into mic, hear yourself from speaker.
//! AEC cancels speaker echo. Verifies no echo accumulation over 20s.
//!
//! Uses the real AudioEngine(Rt, Mic, Speaker) API.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const Rt = @import("std_impl").runtime;
const Mixer = audio.mixer.Mixer(Rt);
const Format = audio.resampler.Format;
const Engine = audio.engine.AudioEngine(Rt, MicDriver, SpeakerDriver);

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 20;

const MicDriver = struct {
    stream: pa.InputStream(i16),
    pub fn init() !MicDriver {
        var s = try pa.InputStream(i16).open(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE });
        try s.start();
        return .{ .stream = s };
    }
    pub fn deinit(self: *MicDriver) void { self.stream.stop() catch {}; self.stream.close(); }
    pub fn read(self: *MicDriver, buf: []i16) !usize { try self.stream.read(buf); return buf.len; }
};

const SpeakerDriver = struct {
    stream: pa.OutputStream(i16),
    pub fn init() !SpeakerDriver {
        var s = try pa.OutputStream(i16).open(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE });
        try s.start();
        return .{ .stream = s };
    }
    pub fn deinit(self: *SpeakerDriver) void { self.stream.stop() catch {}; self.stream.close(); }
    pub fn write(self: *SpeakerDriver, buf: []const i16) !usize { try self.stream.write(buf); return buf.len; }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== E1: AudioEngine Loopback ===\n", .{});
    std.debug.print("Speak into mic. You should hear yourself. No echo buildup.\n", .{});
    std.debug.print("Duration: {d}s\n\n", .{DURATION_S});

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var mic_drv = try MicDriver.init();
    defer mic_drv.deinit();
    var spk_drv = try SpeakerDriver.init();
    defer spk_drv.deinit();

    var engine = try Engine.init(allocator, &mic_drv, &spk_drv, .{
        .enable_aec = true,
        .enable_ns = true,
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
    });
    defer engine.deinit();

    // Create a monitor track: clean audio → mixer → speaker
    const format = Format{ .rate = SAMPLE_RATE, .channels = .mono };
    const monitor = try engine.createTrack(.{ .label = "monitor" });

    try engine.start();
    std.debug.print("Running... speak now!\n\n", .{});

    // Reader thread: readClean → write to monitor track → speaker plays it
    const reader = try std.Thread.spawn(.{}, struct {
        fn run(eng: *Engine, track: *Mixer.Track, fmt: Format, dur: u32) void {
            var buf: [160]i16 = undefined;
            var total: usize = 0;
            const max = @as(usize, dur) * 16000;
            while (total < max) {
                const n = eng.readClean(&buf) orelse break;
                if (n > 0) {
                    track.write(fmt, buf[0..n]) catch break;
                    total += n;
                }
            }
        }
    }.run, .{ &engine, monitor.track, format, DURATION_S });

    // Main thread: wait
    std.Thread.sleep(@as(u64, DURATION_S) * std.time.ns_per_s);

    monitor.ctrl.closeWrite();
    engine.stop();
    reader.join();

    std.debug.print("\nDone.\n\n", .{});
}
