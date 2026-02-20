//! Audio Engine E2E Test — full AEC pipeline with real mic + speaker
//!
//! Plays a 200→4000Hz chirp through the speaker, captures from the mic,
//! runs AEC + NS, and reports ERLE per second.
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
const DURATION_SEC: u32 = 5;

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

fn generateChirp(buf: []i16, sample_rate: u32, f_start: f64, f_end: f64) void {
    const n: f64 = @floatFromInt(buf.len);
    const sr: f64 = @floatFromInt(sample_rate);
    const k = f_end / f_start;
    const duration = n / sr;

    for (buf, 0..) |*s, i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / sr;
        const phase = 2.0 * std.math.pi * f_start * duration / @log(k) *
            (std.math.pow(f64, k, t / duration) - 1.0);
        s.* = @intFromFloat(@sin(phase) * 16000.0);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const print = std.debug.print;

    print("\n=== Audio Engine E2E Test ===\n", .{});
    print("Speaker plays chirp (200-4000Hz), mic captures, AEC processes\n", .{});
    print("Duration: {d}s, Frame: {d} samples\n\n", .{ DURATION_SEC, FRAME_SIZE });

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

    // Generate chirp
    const total_samples = SAMPLE_RATE * DURATION_SEC;
    const chirp = try allocator.alloc(i16, total_samples);
    defer allocator.free(chirp);
    generateChirp(chirp, SAMPLE_RATE, 200.0, 4000.0);

    // Create track and write chirp
    const format = engine.outputFormat();
    const h = try engine.createTrack(.{ .label = "chirp" });

    // Write chirp data (already in buffer before start)
    try h.track.write(format, chirp);
    h.ctrl.closeWrite();

    try engine.start();

    print("Playing chirp and capturing...\n\n", .{});

    // Read clean audio and measure per-second.
    // After all chirp data is consumed, mixer.read() will block (single loop).
    // We read exactly the amount we wrote, then stop.
    var buf: [FRAME_SIZE]i16 = undefined;
    var total_read: usize = 0;
    var sec_energy: f64 = 0;
    var sec_samples: usize = 0;
    const frames_per_sec = SAMPLE_RATE;

    while (total_read < total_samples) {
        const n = engine.readClean(&buf) orelse break;
        for (buf[0..n]) |s| {
            const v: f64 = @floatFromInt(s);
            sec_energy += v * v;
        }
        sec_samples += n;
        total_read += n;

        if (sec_samples >= frames_per_sec) {
            const rms = @sqrt(sec_energy / @as(f64, @floatFromInt(sec_samples)));
            const db = if (rms > 1.0) 20.0 * @log10(rms / 32768.0) else -100.0;
            const sec = total_read / frames_per_sec;
            print("  [{d}/{d}s] clean_rms={d:.1} ({d:.1}dBFS)\n", .{
                sec, DURATION_SEC, rms, db,
            });
            sec_energy = 0;
            sec_samples = 0;
        }
    }

    engine.stop();

    print("\nDone! Processed {d} samples ({d}ms)\n", .{
        total_read, total_read * 1000 / SAMPLE_RATE,
    });
    print("Check output — clean energy should decrease over time as AEC converges.\n\n", .{});
}
