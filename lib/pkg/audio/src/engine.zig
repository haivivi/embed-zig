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
//!     clean_ch.send(clean)          // deliver to application
//! ```
//!
//! ## Why playback/capture instead of cancellation(mic, ref)?
//!
//! `speex_echo_cancellation(mic, ref, out)` requires time-aligned mic and ref
//! frames. In a multi-threaded pipeline, mic and speaker run at slightly
//! different rates, causing frame misalignment and degraded AEC.
//!
//! `speex_echo_playback()` + `speex_echo_capture()` lets SpeexDSP manage
//! its own internal reference buffer with proper delay tracking.
//!
//! ## Usage
//!
//! ```zig
//! const Rt = @import("runtime");
//! const Engine = AudioEngine(Rt);
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
    clean_channel_depth: usize = 8,
};

pub fn AudioEngine(comptime Rt: type) type {
    const MixerType = mixer_mod.Mixer(Rt);
    const Format = resampler_mod.Format;

    return struct {
        const Self = @This();

        pub const Mixer = MixerType;
        pub const TrackHandle = MixerType.TrackHandle;

        allocator: std.mem.Allocator,
        config: EngineConfig,
        mic: *anyopaque,
        speaker: *anyopaque,
        mic_read_fn: *const fn (*anyopaque, []i16) anyerror!usize,
        speaker_write_fn: *const fn (*anyopaque, []const i16) anyerror!usize,

        aec: ?aec_mod.Aec,
        ns: ?ns_mod.NoiseSuppressor,
        mixer: MixerType,
        echo_mutex: Rt.Mutex,

        // Clean audio output channel (fixed-size frames for AEC alignment)
        clean_buf_pool: []i16,
        clean_write_pos: usize,
        clean_read_pos: usize,
        clean_mutex: Rt.Mutex,
        clean_not_empty: Rt.Condition,
        clean_not_full: Rt.Condition,
        clean_closed: bool,

        mic_thread: ?std.Thread,
        speaker_thread: ?std.Thread,
        running: std.atomic.Value(bool),
        speaker_ready: std.atomic.Value(bool),

        pub fn init(
            allocator: std.mem.Allocator,
            mic: anytype,
            speaker: anytype,
            config: EngineConfig,
        ) !Self {
            const MicPtr = @TypeOf(mic);
            const SpeakerPtr = @TypeOf(speaker);
            const MicType = @typeInfo(MicPtr).pointer.child;
            const SpeakerType = @typeInfo(SpeakerPtr).pointer.child;

            const mic_fn = struct {
                fn read(ctx: *anyopaque, buf: []i16) anyerror!usize {
                    const m: *MicType = @ptrCast(@alignCast(ctx));
                    return m.read(buf);
                }
            }.read;

            const speaker_fn = struct {
                fn write(ctx: *anyopaque, buf: []const i16) anyerror!usize {
                    const s: *SpeakerType = @ptrCast(@alignCast(ctx));
                    return s.write(buf);
                }
            }.write;

            // Ring buffer: 500ms of clean audio for the channel
            const ring_samples = @as(usize, config.sample_rate) / 2;
            const clean_buf = try allocator.alloc(i16, ring_samples);
            errdefer allocator.free(clean_buf);

            return .{
                .allocator = allocator,
                .config = config,
                .mic = @ptrCast(@alignCast(mic)),
                .speaker = @ptrCast(@alignCast(speaker)),
                .mic_read_fn = mic_fn,
                .speaker_write_fn = speaker_fn,
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

            self.speaker_thread = try std.Thread.spawn(.{}, speakerTask, .{self});
            self.mic_thread = try std.Thread.spawn(.{}, micTask, .{self});
        }

        pub fn stop(self: *Self) void {
            if (!self.running.load(.acquire)) return;
            self.running.store(false, .release);

            // Close clean channel to unblock readers
            self.clean_mutex.lock();
            self.clean_closed = true;
            self.clean_not_empty.broadcast();
            self.clean_not_full.broadcast();
            self.clean_mutex.unlock();

            // Close mixer to unblock speaker task's read
            self.mixer.close();

            if (self.mic_thread) |t| {
                t.join();
                self.mic_thread = null;
            }
            if (self.speaker_thread) |t| {
                t.join();
                self.speaker_thread = null;
            }
        }

        // ================================================================
        // Public API
        // ================================================================

        /// Read clean (AEC + NS processed) audio into buf.
        /// Blocks until data is available. Returns null when engine is stopped.
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

        /// Create a new playback track. Returns a TrackHandle with
        /// .track (for writing) and .ctrl (for gain/close control).
        pub fn createTrack(self: *Self, config: MixerType.TrackConfig) !TrackHandle {
            return self.mixer.createTrack(config);
        }

        /// Destroy a track control after the track is done.
        pub fn destroyTrackCtrl(self: *Self, ctrl: *MixerType.TrackCtrl) void {
            self.mixer.destroyTrackCtrl(ctrl);
        }

        /// Get the output format of the mixer.
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

                _ = self.speaker_write_fn(self.speaker, frame_buf[0..n]) catch continue;

                self.echo_mutex.lock();
                if (self.aec) |*a| {
                    // Feed AEC in frame_size chunks
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

            // Wait until speaker has fed at least one playback frame
            while (self.running.load(.acquire) and !self.speaker_ready.load(.acquire)) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }

            var mic_buf = [_]i16{0} ** 4096;
            var clean = [_]i16{0} ** 4096;

            while (self.running.load(.acquire)) {
                const n = self.mic_read_fn(self.mic, mic_buf[0..frame_size]) catch continue;
                if (n == 0) continue;

                // Zero-pad if partial frame
                if (n < frame_size) {
                    @memset(mic_buf[n..frame_size], 0);
                }

                // AEC: process in frame_size chunks
                self.echo_mutex.lock();
                if (self.aec) |*a| {
                    a.capture(mic_buf[0..frame_size], clean[0..frame_size]);
                } else {
                    @memcpy(clean[0..frame_size], mic_buf[0..frame_size]);
                }
                self.echo_mutex.unlock();

                // Noise suppression (in-place)
                if (self.ns) |*ns| {
                    _ = ns.process(clean[0..frame_size]);
                }

                // Push to clean channel
                self.pushClean(clean[0..frame_size]);
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const TestRt = @import("std_impl").runtime;

const MockMic = struct {
    sample_value: i16 = 0,
    frame_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn read(self: *MockMic, buffer: []i16) !usize {
        if (self.stopped.load(.acquire)) return 0;
        for (buffer) |*s| s.* = self.sample_value;
        _ = self.frame_count.fetchAdd(1, .acq_rel);
        std.Thread.sleep(5 * std.time.ns_per_ms);
        return buffer.len;
    }
};

const MockSpeaker = struct {
    last_sample: std.atomic.Value(i16) = std.atomic.Value(i16).init(0),
    write_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn write(self: *MockSpeaker, buffer: []const i16) !usize {
        if (buffer.len > 0) {
            self.last_sample.store(buffer[0], .release);
        }
        _ = self.write_count.fetchAdd(1, .acq_rel);
        return buffer.len;
    }
};

test "engine init and deinit" {
    var mic = MockMic{};
    var speaker = MockSpeaker{};
    var engine = try AudioEngine(TestRt).init(testing.allocator, &mic, &speaker, .{
        .enable_aec = false,
        .enable_ns = false,
    });
    defer engine.deinit();
}

test "engine start and stop without AEC" {
    var mic = MockMic{ .sample_value = 1000 };
    var speaker = MockSpeaker{};
    var engine = try AudioEngine(TestRt).init(testing.allocator, &mic, &speaker, .{
        .enable_aec = false,
        .enable_ns = false,
    });
    defer engine.deinit();

    // Create a track with some data so mixer doesn't block forever
    const h = try engine.createTrack(.{ .label = "test" });
    const format = engine.outputFormat();
    var tone = [_]i16{500} ** 160;
    try h.track.write(format, &tone);
    h.ctrl.closeWrite();

    try engine.start();

    // Read clean audio
    var clean: [160]i16 = undefined;
    const n = engine.readClean(&clean);
    try testing.expect(n != null);
    try testing.expect(n.? > 0);

    // Mic data (1000) should come through clean channel
    var found_nonzero = false;
    for (clean[0..n.?]) |s| {
        if (s != 0) found_nonzero = true;
    }
    try testing.expect(found_nonzero);

    mic.stopped.store(true, .release);
    engine.stop();
}

test "engine with AEC" {
    var mic = MockMic{};
    var speaker = MockSpeaker{};
    var engine = try AudioEngine(TestRt).init(testing.allocator, &mic, &speaker, .{
        .enable_aec = true,
        .enable_ns = true,
    });
    defer engine.deinit();

    const h = try engine.createTrack(.{});
    const format = engine.outputFormat();
    var tone = [_]i16{500} ** 160;
    try h.track.write(format, &tone);
    h.ctrl.closeWrite();

    try engine.start();

    // Should be able to read at least one frame
    var clean: [160]i16 = undefined;
    const n = engine.readClean(&clean);
    try testing.expect(n != null);

    mic.stopped.store(true, .release);
    engine.stop();
}

test "engine createTrack and play" {
    var mic = MockMic{};
    var speaker = MockSpeaker{};
    var engine = try AudioEngine(TestRt).init(testing.allocator, &mic, &speaker, .{
        .enable_aec = false,
        .enable_ns = false,
    });
    defer engine.deinit();

    const h = try engine.createTrack(.{ .label = "music", .gain = 0.5 });
    const format = engine.outputFormat();

    // Write some audio to the track
    var data = [_]i16{10000} ** 320;
    try h.track.write(format, &data);
    h.ctrl.closeWrite();

    try engine.start();

    // Wait for speaker to receive data
    var retries: u32 = 0;
    while (speaker.write_count.load(.acquire) == 0 and retries < 100) : (retries += 1) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try testing.expect(speaker.write_count.load(.acquire) > 0);

    mic.stopped.store(true, .release);
    engine.stop();
}
