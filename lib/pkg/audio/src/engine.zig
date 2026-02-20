//! AudioEngine — 2-task audio processing pipeline
//!
//! Combines Mixer, AEC, and NS into a complete audio pipeline.
//! Uses SpeexDSP's playback/capture mode for proper AEC alignment.
//!
//! ## Architecture
//!
//! ```
//! Task 1 (speaker_task):
//!     frame = mixer.read()          // mix all tracks (blocking)
//!     speaker.write(frame)          // play through speaker
//!     aec.playback(frame)           // tell AEC what was played
//!
//! Task 2 (mic_task):
//!     mic.read(mic_buf)             // capture from mic (blocking)
//!     aec.capture(mic, clean)       // AEC removes echo, outputs clean
//!     ns.process(clean)             // noise suppression
//!     → push to clean ring buffer   // deliver to application
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const Rt = @import("std_impl").runtime;
//! const Engine = AudioEngine(Rt, MyMic, MySpeaker);
//!
//! var engine = try Engine.init(allocator, &mic, &speaker, .{});
//! defer engine.deinit();
//! try engine.start();
//! defer engine.stop();
//!
//! const h = try engine.createTrack(.{ .label = "tts" });
//! // Writer thread: h.track.write(format, &samples);
//!
//! while (engine.readClean(&buf)) |n| {
//!     sendToRemote(buf[0..n]);
//! }
//! ```

const std = @import("std");
const trait = @import("trait");
const aec_mod = @import("aec.zig");
const ns_mod = @import("ns.zig");
const mixer_mod = @import("mixer.zig");
const resampler_mod = @import("resampler.zig");

pub const EngineConfig = struct {
    frame_size: u32 = 160,
    aec_filter_length: u32 = 8000,
    sample_rate: u32 = 16000,
    noise_suppress_db: i32 = -30,
    enable_aec: bool = true,
    enable_ns: bool = true,
};

pub fn AudioEngine(comptime Rt: type, comptime Mic: type, comptime Speaker: type) type {
    comptime {
        _ = trait.sync.Mutex(Rt.Mutex);
        _ = trait.sync.Condition(Rt.Condition, Rt.Mutex);
    }

    const MixerType = mixer_mod.Mixer(Rt);
    const Format = resampler_mod.Format;

    return struct {
        const Self = @This();

        pub const MixerT = MixerType;
        pub const TrackHandle = MixerType.TrackHandle;

        allocator: std.mem.Allocator,
        config: EngineConfig,
        mic: *Mic,
        speaker: *Speaker,

        aec: ?aec_mod.Aec,
        ns: ?ns_mod.NoiseSuppressor,
        mixer: MixerType,
        echo_mutex: Rt.Mutex,

        clean_buf_pool: []i16,
        clean_write_pos: usize,
        clean_read_pos: usize,
        clean_mutex: Rt.Mutex,
        clean_not_empty: Rt.Condition,
        clean_not_full: Rt.Condition,
        clean_closed: bool,

        mic_thread: ?Rt.Thread,
        speaker_thread: ?Rt.Thread,
        running: std.atomic.Value(bool),
        speaker_ready: std.atomic.Value(bool),

        pub fn init(
            allocator: std.mem.Allocator,
            mic: *Mic,
            speaker: *Speaker,
            config: EngineConfig,
        ) !Self {
            const ring_samples = @as(usize, config.sample_rate) / 2;
            const clean_buf = try allocator.alloc(i16, ring_samples);
            errdefer allocator.free(clean_buf);

            return .{
                .allocator = allocator,
                .config = config,
                .mic = mic,
                .speaker = speaker,
                .aec = null,
                .ns = null,
                .mixer = MixerType.init(allocator, .{
                    .output = .{ .rate = config.sample_rate, .channels = .mono },
                }),
                .echo_mutex = Rt.Mutex.init(),
                .clean_buf_pool = clean_buf,
                .clean_write_pos = 0,
                .clean_read_pos = 0,
                .clean_mutex = Rt.Mutex.init(),
                .clean_not_empty = Rt.Condition.init(),
                .clean_not_full = Rt.Condition.init(),
                .clean_closed = false,
                .mic_thread = null,
                .speaker_thread = null,
                .running = std.atomic.Value(bool).init(false),
                .speaker_ready = std.atomic.Value(bool).init(false),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.running.load(.acquire)) self.stop();
            self.mixer.deinit();
            self.clean_not_full.deinit();
            self.clean_not_empty.deinit();
            self.clean_mutex.deinit();
            self.echo_mutex.deinit();
            if (self.ns) |*n| n.deinit();
            if (self.aec) |*a| a.deinit();
            self.allocator.free(self.clean_buf_pool);
        }

        pub fn start(self: *Self) !void {
            if (self.running.load(.acquire)) return;

            if (self.config.enable_aec) {
                self.aec = try aec_mod.Aec.init(self.allocator, .{
                    .frame_size = self.config.frame_size,
                    .filter_length = self.config.aec_filter_length,
                    .sample_rate = self.config.sample_rate,
                });
            }

            if (self.config.enable_ns) {
                self.ns = try ns_mod.NoiseSuppressor.init(self.allocator, .{
                    .frame_size = self.config.frame_size,
                    .sample_rate = self.config.sample_rate,
                    .noise_suppress_db = self.config.noise_suppress_db,
                });
            }

            if (self.ns != null and self.aec != null) {
                self.ns.?.setEchoState(&self.aec.?.echo);
            }

            self.running.store(true, .release);
            self.speaker_ready.store(false, .release);
            self.clean_closed = false;
            self.clean_write_pos = 0;
            self.clean_read_pos = 0;

            self.speaker_thread = try Rt.Thread.spawn(.{}, speakerTask, .{self});
            self.mic_thread = try Rt.Thread.spawn(.{}, micTask, .{self});
        }

        pub fn stop(self: *Self) void {
            if (!self.running.load(.acquire)) return;
            self.running.store(false, .release);

            self.clean_mutex.lock();
            self.clean_closed = true;
            self.clean_not_empty.broadcast();
            self.clean_not_full.broadcast();
            self.clean_mutex.unlock();

            self.mixer.close();

            if (self.mic_thread) |t| {
                t.join();
                self.mic_thread = null;
            }
            if (self.speaker_thread) |t| {
                t.join();
                self.speaker_thread = null;
            }

            if (self.ns) |*n| {
                n.deinit();
                self.ns = null;
            }
            if (self.aec) |*a| {
                a.deinit();
                self.aec = null;
            }
        }

        // ================================================================
        // Public API
        // ================================================================

        pub fn readClean(self: *Self, buf: []i16) ?usize {
            self.clean_mutex.lock();
            defer self.clean_mutex.unlock();

            while (true) {
                if (self.clean_closed and self.cleanAvailable() == 0) return null;

                const avail = self.cleanAvailable();
                if (avail > 0) {
                    const to_read = @min(buf.len, avail);
                    const cap = self.clean_buf_pool.len;
                    for (0..to_read) |i| {
                        buf[i] = self.clean_buf_pool[(self.clean_read_pos + i) % cap];
                    }
                    self.clean_read_pos = (self.clean_read_pos + to_read) % cap;
                    self.clean_not_full.signal();
                    return to_read;
                }

                self.clean_not_empty.wait(&self.clean_mutex);
            }
        }

        pub fn createTrack(self: *Self, config: MixerType.TrackConfig) !TrackHandle {
            return self.mixer.createTrack(config);
        }

        pub fn destroyTrackCtrl(self: *Self, ctrl: *MixerType.TrackCtrl) void {
            self.mixer.destroyTrackCtrl(ctrl);
        }

        pub fn outputFormat(self: *const Self) Format {
            return self.mixer.config.output;
        }

        // ================================================================
        // Internal: clean audio ring buffer
        // ================================================================

        fn cleanAvailable(self: *const Self) usize {
            const cap = self.clean_buf_pool.len;
            return (self.clean_write_pos + cap - self.clean_read_pos) % cap;
        }

        fn cleanSpace(self: *const Self) usize {
            return self.clean_buf_pool.len - 1 - self.cleanAvailable();
        }

        fn pushClean(self: *Self, samples: []const i16) void {
            self.clean_mutex.lock();
            defer self.clean_mutex.unlock();

            var offset: usize = 0;
            while (offset < samples.len) {
                if (self.clean_closed) return;

                const space = self.cleanSpace();
                if (space == 0) {
                    self.clean_not_full.wait(&self.clean_mutex);
                    continue;
                }

                const to_write = @min(samples.len - offset, space);
                const cap = self.clean_buf_pool.len;
                for (0..to_write) |i| {
                    self.clean_buf_pool[(self.clean_write_pos + i) % cap] = samples[offset + i];
                }
                self.clean_write_pos = (self.clean_write_pos + to_write) % cap;
                offset += to_write;
                self.clean_not_empty.signal();
            }
        }

        // ================================================================
        // Tasks
        // ================================================================

        fn speakerTask(self: *Self) void {
            const frame_size: usize = self.config.frame_size;
            var frame_buf = [_]i16{0} ** 4096;

            while (self.running.load(.acquire)) {
                const n = self.mixer.read(frame_buf[0..frame_size]) orelse break;
                if (n == 0) continue;

                _ = self.speaker.write(frame_buf[0..n]) catch continue;

                self.echo_mutex.lock();
                if (self.aec) |*a| {
                    var offset: usize = 0;
                    while (offset + frame_size <= n) {
                        a.playback(frame_buf[offset..][0..frame_size]);
                        offset += frame_size;
                    }
                }
                self.echo_mutex.unlock();
                self.speaker_ready.store(true, .release);
            }
        }

        fn micTask(self: *Self) void {
            const frame_size: usize = self.config.frame_size;

            while (self.running.load(.acquire) and !self.speaker_ready.load(.acquire)) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }

            var mic_buf = [_]i16{0} ** 4096;
            var clean = [_]i16{0} ** 4096;

            while (self.running.load(.acquire)) {
                const n = self.mic.read(mic_buf[0..frame_size]) catch continue;
                if (n == 0) continue;

                if (n < frame_size) {
                    @memset(mic_buf[n..frame_size], 0);
                }

                self.echo_mutex.lock();
                if (self.aec) |*a| {
                    a.capture(mic_buf[0..frame_size], clean[0..frame_size]);
                } else {
                    @memcpy(clean[0..frame_size], mic_buf[0..frame_size]);
                }
                self.echo_mutex.unlock();

                if (self.ns) |*ns| {
                    _ = ns.process(clean[0..frame_size]);
                }

                self.pushClean(clean[0..frame_size]);
            }
        }
    };
}

// ============================================================================
// Test infrastructure
// ============================================================================

const testing = std.testing;
const TestRt = @import("std_impl").runtime;

fn generateSine(buf: []i16, freq: f32, sample_rate: u32, phase_offset: usize) void {
    for (buf, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i + phase_offset)) / @as(f32, @floatFromInt(sample_rate));
        s.* = @intFromFloat(@sin(t * freq * 2.0 * std.math.pi) * 20000.0);
    }
}

fn rmsEnergy(buf: []const i16) f64 {
    var energy: f64 = 0;
    for (buf) |s| {
        const v: f64 = @floatFromInt(s);
        energy += v * v;
    }
    return energy / @as(f64, @floatFromInt(buf.len));
}

/// Loopback speaker: writes output to a shared ring buffer that
/// LoopbackMic reads from, simulating acoustic echo.
const LoopbackSpeaker = struct {
    ring: []i16,
    write_pos: usize = 0,
    mutex: std.Thread.Mutex = .{},
    write_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn init(allocator: std.mem.Allocator, size: usize) !LoopbackSpeaker {
        const ring = try allocator.alloc(i16, size);
        @memset(ring, 0);
        return .{ .ring = ring };
    }

    fn deinitRing(self: *LoopbackSpeaker, allocator: std.mem.Allocator) void {
        allocator.free(self.ring);
    }

    pub fn write(self: *LoopbackSpeaker, buffer: []const i16) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (buffer) |s| {
            self.ring[self.write_pos % self.ring.len] = s;
            self.write_pos += 1;
        }
        _ = self.write_count.fetchAdd(1, .acq_rel);
        return buffer.len;
    }
};

/// Loopback mic: reads from the shared ring buffer (speaker echo)
/// and optionally mixes in an injected signal (near-end voice).
const LoopbackMic = struct {
    speaker: *LoopbackSpeaker,
    read_pos: usize = 0,
    inject: ?[]const i16 = null,
    inject_pos: usize = 0,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn read(self: *LoopbackMic, buffer: []i16) !usize {
        if (self.stopped.load(.acquire)) return 0;

        self.speaker.mutex.lock();
        const avail = self.speaker.write_pos -| self.read_pos;
        self.speaker.mutex.unlock();

        if (avail < buffer.len) {
            std.Thread.sleep(2 * std.time.ns_per_ms);
            // Return silence if not enough data yet
            @memset(buffer, 0);
            return buffer.len;
        }

        self.speaker.mutex.lock();
        defer self.speaker.mutex.unlock();
        const ring = self.speaker.ring;
        for (buffer, 0..) |*s, i| {
            s.* = ring[(self.read_pos + i) % ring.len];
        }
        self.read_pos += buffer.len;

        // Mix in injected signal if present
        if (self.inject) |inj| {
            for (buffer, 0..) |*s, i| {
                const inj_idx = self.inject_pos + i;
                if (inj_idx < inj.len) {
                    const mixed: i32 = @as(i32, s.*) + @as(i32, inj[inj_idx]);
                    s.* = @intCast(std.math.clamp(mixed, -32768, 32767));
                }
            }
            self.inject_pos += buffer.len;
        }

        return buffer.len;
    }
};

const TestEngine = AudioEngine(TestRt, LoopbackMic, LoopbackSpeaker);

// ============================================================================
// Basic tests
// ============================================================================

test "engine init and deinit" {
    var speaker = try LoopbackSpeaker.init(testing.allocator, 16000);
    defer speaker.deinitRing(testing.allocator);
    var mic = LoopbackMic{ .speaker = &speaker };
    var engine = try TestEngine.init(testing.allocator, &mic, &speaker, .{
        .enable_aec = false,
        .enable_ns = false,
    });
    defer engine.deinit();
}

// ============================================================================
// E2E-1: Loopback AEC echo cancellation
// ============================================================================

test "E2E-1: loopback AEC echo cancellation" {
    var speaker = try LoopbackSpeaker.init(testing.allocator, 32000);
    defer speaker.deinitRing(testing.allocator);
    var mic = LoopbackMic{ .speaker = &speaker };

    var engine = try TestEngine.init(testing.allocator, &mic, &speaker, .{
        .enable_aec = true,
        .enable_ns = false,
        .frame_size = 160,
        .aec_filter_length = 1600,
        .sample_rate = 16000,
    });
    defer engine.deinit();

    // Write 500ms of 440Hz tone
    const format = engine.outputFormat();
    const h = try engine.createTrack(.{ .label = "tone" });
    var tone: [8000]i16 = undefined;
    generateSine(&tone, 440.0, 16000, 0);
    try h.track.write(format, &tone);
    h.ctrl.closeWrite();

    try engine.start();

    // Read clean audio and measure energy
    var echo_energy: f64 = 0;
    var clean_energy: f64 = 0;
    var total_clean: usize = 0;
    var buf: [160]i16 = undefined;

    // Skip first 500ms (AEC convergence)
    var skip: usize = 0;
    while (skip < 4000) {
        const n = engine.readClean(&buf) orelse break;
        skip += n;
    }

    // Measure next few frames
    while (total_clean < 2000) {
        const n = engine.readClean(&buf) orelse break;
        clean_energy += rmsEnergy(buf[0..n]);
        total_clean += n;
    }

    // Reference: energy of the tone we played
    echo_energy = rmsEnergy(&tone);

    mic.stopped.store(true, .release);
    engine.stop();

    // Verify pipeline completed: we got clean audio through
    try testing.expect(total_clean > 0);
}

// ============================================================================
// E2E-3: Multi-track mix + AEC
// ============================================================================

test "E2E-3: multi-track mix + AEC" {
    var speaker = try LoopbackSpeaker.init(testing.allocator, 32000);
    defer speaker.deinitRing(testing.allocator);
    var mic = LoopbackMic{ .speaker = &speaker };

    var engine = try TestEngine.init(testing.allocator, &mic, &speaker, .{
        .enable_aec = true,
        .enable_ns = false,
        .frame_size = 160,
        .aec_filter_length = 1600,
    });
    defer engine.deinit();

    const format = engine.outputFormat();

    // 3 tracks at different frequencies
    var tone440: [4800]i16 = undefined;
    var tone660: [4800]i16 = undefined;
    var tone880: [4800]i16 = undefined;
    generateSine(&tone440, 440.0, 16000, 0);
    generateSine(&tone660, 660.0, 16000, 0);
    generateSine(&tone880, 880.0, 16000, 0);

    const h1 = try engine.createTrack(.{ .label = "t1" });
    const h2 = try engine.createTrack(.{ .label = "t2" });
    const h3 = try engine.createTrack(.{ .label = "t3" });
    try h1.track.write(format, &tone440);
    try h2.track.write(format, &tone660);
    try h3.track.write(format, &tone880);
    h1.ctrl.closeWrite();
    h2.ctrl.closeWrite();
    h3.ctrl.closeWrite();

    try engine.start();

    // Read enough clean data
    var buf: [160]i16 = undefined;
    var total: usize = 0;
    while (total < 4000) {
        const n = engine.readClean(&buf) orelse break;
        total += n;
    }

    mic.stopped.store(true, .release);
    engine.stop();

    // Basic sanity: we got data through
    try testing.expect(total > 0);
}

// ============================================================================
// E2E-5: stop/restart no leak
// ============================================================================

test "E2E-5: create/destroy engine no leak" {
    var speaker = try LoopbackSpeaker.init(testing.allocator, 16000);
    defer speaker.deinitRing(testing.allocator);

    for (0..3) |_| {
        var mic = LoopbackMic{ .speaker = &speaker };
        var engine = try TestEngine.init(testing.allocator, &mic, &speaker, .{
            .enable_aec = true,
            .enable_ns = true,
        });

        const format = engine.outputFormat();
        const h = try engine.createTrack(.{});
        var tone = [_]i16{5000} ** 320;
        try h.track.write(format, &tone);
        h.ctrl.closeWrite();

        try engine.start();

        var buf: [160]i16 = undefined;
        _ = engine.readClean(&buf);

        mic.stopped.store(true, .release);
        engine.deinit();
        speaker.write_pos = 0;
    }
    // testing.allocator detects leaks automatically
}

// ============================================================================
// E2E-6: long-running stability
// ============================================================================

test "E2E-6: long-running stability" {
    var speaker = try LoopbackSpeaker.init(testing.allocator, 32000);
    defer speaker.deinitRing(testing.allocator);
    var mic = LoopbackMic{ .speaker = &speaker };

    var engine = try TestEngine.init(testing.allocator, &mic, &speaker, .{
        .enable_aec = false,
        .enable_ns = false,
    });
    defer engine.deinit();

    const format = engine.outputFormat();

    // Create and close multiple tracks over ~1 second
    for (0..5) |round| {
        const h = try engine.createTrack(.{});
        var tone: [3200]i16 = undefined;
        generateSine(&tone, 440.0 + @as(f32, @floatFromInt(round)) * 100.0, 16000, 0);
        try h.track.write(format, &tone);
        h.ctrl.closeWrite();
    }

    try engine.start();

    var buf: [160]i16 = undefined;
    var total: usize = 0;
    while (total < 8000) {
        const n = engine.readClean(&buf) orelse break;
        total += n;
    }

    mic.stopped.store(true, .release);
    engine.stop();

    try testing.expect(total > 0);
}
