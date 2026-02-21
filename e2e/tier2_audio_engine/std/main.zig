//! Audio Engine Live Test — sweep background + AEC + mic monitor
//!
//! Plays a 20Hz→8kHz sweep through the speaker, captures from the mic,
//! runs AEC to remove the sweep echo, and plays clean audio (your voice)
//! back through the speaker. Speak into the mic — you should hear yourself
//! but NOT the sweep in the monitored output.
//!
//! Run: cd e2e/tier2_audio_engine/std && zig build run

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const Rt = @import("std_impl").runtime;
const Mixer = audio.mixer.Mixer(Rt);
const Format = audio.resampler.Format;
const Engine = audio.engine.AudioEngine(Rt, MicDriver, SpeakerDriver);

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const SWEEP_DURATION_S: f64 = 10.0;
const SWEEP_AMP: f64 = 3000.0;

const MicDriver = struct {
    stream: pa.InputStream(i16),

    pub fn init() !MicDriver {
        var stream = try pa.InputStream(i16).open(.{
            .sample_rate = SAMPLE_RATE,
            .channels = 1,
            .frames_per_buffer = FRAME_SIZE,
        });
        try stream.start();
        return .{ .stream = stream };
    }

    pub fn deinit(self: *MicDriver) void {
        self.stream.stop() catch {};
        self.stream.close();
    }

    pub fn read(self: *MicDriver, buffer: []i16) !usize {
        try self.stream.read(buffer);
        return buffer.len;
    }
};

const SpeakerDriver = struct {
    stream: pa.OutputStream(i16),

    pub fn init() !SpeakerDriver {
        var stream = try pa.OutputStream(i16).open(.{
            .sample_rate = SAMPLE_RATE,
            .channels = 1,
            .frames_per_buffer = FRAME_SIZE,
        });
        try stream.start();
        return .{ .stream = stream };
    }

    pub fn deinit(self: *SpeakerDriver) void {
        self.stream.stop() catch {};
        self.stream.close();
    }

    pub fn write(self: *SpeakerDriver, buffer: []const i16) !usize {
        try self.stream.write(buffer);
        return buffer.len;
    }
};

fn generateSweepFrame(buf: []i16, sample_idx: *usize) void {
    const f_start: f64 = 20.0;
    const f_end: f64 = 8000.0;
    const sr: f64 = @floatFromInt(SAMPLE_RATE);

    for (buf) |*s| {
        const t: f64 = @as(f64, @floatFromInt(sample_idx.*)) / sr;
        const progress = @mod(t, SWEEP_DURATION_S) / SWEEP_DURATION_S;
        const freq = f_start + (f_end - f_start) * progress;
        const phase = 2.0 * std.math.pi * freq * t;
        s.* = @intFromFloat(@sin(phase) * SWEEP_AMP);
        sample_idx.* += 1;
    }
}

var g_running = std.atomic.Value(bool).init(true);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const print = std.debug.print;

    print("\n=== Audio Engine Live Test ===\n", .{});
    print("Background: 20Hz→8kHz sweep (10s cycle)\n", .{});
    print("Speak into mic — you should hear yourself, NOT the sweep\n", .{});
    print("Press Ctrl+C to stop\n\n", .{});

    // Run for 15 seconds then stop
    const RUN_DURATION_S: u64 = 15;

    try pa.init();
    defer pa.deinit();

    print("PortAudio: {s}\n", .{pa.versionText()});
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| {
        print("Input:  {s}\n", .{info.name});
    }
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| {
        print("Output: {s}\n", .{info.name});
    }
    print("\n", .{});

    var mic_drv = try MicDriver.init();
    defer mic_drv.deinit();
    var spk_drv = try SpeakerDriver.init();
    defer spk_drv.deinit();

    var engine = try Engine.init(allocator, &mic_drv, &spk_drv, .{
        .frame_size = FRAME_SIZE,
        .aec_filter_length = 8000,
        .sample_rate = SAMPLE_RATE,
        .enable_aec = true,
        .enable_ns = true,
        .noise_suppress_db = -30,
    });
    defer engine.deinit();

    const format = Format{ .rate = SAMPLE_RATE, .channels = .mono };

    // Sweep writer thread: continuously generates sweep frames and writes to a track
    const sweep_thread = try std.Thread.spawn(.{}, struct {
        fn run(eng: *Engine, fmt: Format) void {
            var sample_idx: usize = 0;
            while (g_running.load(.acquire)) {
                const h = eng.createTrack(.{ .label = "sweep" }) catch break;
                // Write 1 second at a time
                var buf: [SAMPLE_RATE]i16 = undefined;
                var offset: usize = 0;
                while (offset < SAMPLE_RATE and g_running.load(.acquire)) {
                    const chunk = @min(FRAME_SIZE, SAMPLE_RATE - offset);
                    generateSweepFrame(buf[offset..][0..chunk], &sample_idx);
                    offset += chunk;
                }
                h.track.write(fmt, buf[0..offset]) catch break;
                h.ctrl.closeWrite();
            }
        }
    }.run, .{ &engine, format });

    // Monitor writer thread: reads clean audio and writes it back as a second track
    const monitor_thread = try std.Thread.spawn(.{}, struct {
        fn run(eng: *Engine, fmt: Format) void {
            while (g_running.load(.acquire)) {
                var clean_buf: [FRAME_SIZE]i16 = undefined;
                const n = eng.readClean(&clean_buf) orelse break;
                if (n == 0) continue;

                // Write clean audio back to mixer as a monitor track
                const h = eng.createTrack(.{ .label = "monitor" }) catch continue;
                h.track.write(fmt, clean_buf[0..n]) catch {
                    h.ctrl.closeWrite();
                    continue;
                };
                h.ctrl.closeWrite();
            }
        }
    }.run, .{ &engine, format });

    try engine.start();

    print("[live] Running for {d}s... speak into mic\n", .{RUN_DURATION_S});

    // Main thread: run for duration, print dots
    var elapsed: u64 = 0;
    while (elapsed < RUN_DURATION_S and g_running.load(.acquire)) {
        std.Thread.sleep(1 * std.time.ns_per_s);
        elapsed += 1;
        print("  [{d}/{d}s]\n", .{ elapsed, RUN_DURATION_S });
    }
    g_running.store(false, .release);

    print("\n[live] Stopping...\n", .{});
    engine.stop();
    sweep_thread.join();
    monitor_thread.join();

    print("[live] Done.\n\n", .{});
}
