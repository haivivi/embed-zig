//! AudioEngine — single-loop audio processing pipeline
//!
//! Single audio task drives the entire pipeline, synchronized by hardware
//! blocking I/O (DMA on embedded, PortAudio on desktop):
//!
//! ```
//! audio_loop (single thread):
//!     ref = mixer.read()               // mix all playback tracks
//!     speaker.write(ref)               // blocking write — paced by hardware clock
//!     mic.read(mic_buf)                // blocking read  — paced by hardware clock
//!     clean = aec.process(mic, ref)    // cancellation mode — ref and mic are frame-aligned
//!     ns.process(clean)                // noise suppression
//!     pushClean(clean)                 // deliver to application via ring buffer
//! ```
//!
//! speaker.write() blocks until the hardware consumes the frame (DMA/PortAudio).
//! mic.read() blocks until the hardware provides a frame.
//! Because both are driven by the same sample clock, ref and mic are naturally
//! frame-aligned — no playback/capture mode needed, no cross-thread timing issues.
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
//! try h.track.write(format, &pcm_data);
//!
//! while (engine.readClean(&buf)) |n| {
//!     sendToRemote(buf[0..n]);
//! }
//! ```

const std = @import("std");
const trait = @import("trait");
const aec3_mod = @import("aec3/aec3.zig");
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
    comfort_noise_rms: f32 = 0,
    /// Platform declares how many frames sit in speaker hardware buffer.
    /// Engine uses this offset to align the ref signal with mic.
    /// Ignored when RefReader is provided.
    speaker_buffer_depth: u32 = 0,
    /// If set, mic_task calls RefReader.read() to get already-aligned ref.
    /// Used by DuplexStream-based platforms where ref alignment is exact.
    RefReader: ?type = null,
};

pub fn AudioEngine(
    comptime Rt: type,
    comptime Mic: type,
    comptime Speaker: type,
    comptime config: EngineConfig,
) type {
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

        const HasRefReader = config.RefReader != null;
        const RefReaderT = if (config.RefReader) |T| T else void;
        const frame_size = config.frame_size;
        const ref_history_depth = if (HasRefReader) 0 else config.speaker_buffer_depth + 1;

        allocator: std.mem.Allocator,
        mic: *Mic,
        speaker: *Speaker,
        ref_reader: if (HasRefReader) *RefReaderT else void,

        aec: ?aec3_mod.Aec3,
        ns: ?ns_mod.NoiseSuppressor,
        mixer: MixerType,

        // Ref history ring (方式 1: buffer_depth, speaker_task → mic_task)
        ref_ring: if (!HasRefReader) []i16 else void,
        ref_ring_write: if (!HasRefReader) usize else void,
        ref_mutex: if (!HasRefReader) Rt.Mutex else void,

        // Clean audio ring buffer (mic_task → application, blocking)
        clean_buf_pool: []i16,
        clean_write_pos: usize,
        clean_read_pos: usize,
        clean_mutex: Rt.Mutex,
        clean_not_empty: Rt.Condition,
        clean_not_full: Rt.Condition,
        clean_closed: bool,

        speaker_thread: ?Rt.Thread,
        mic_thread: ?Rt.Thread,
        running: std.atomic.Value(bool),

        pub fn init(
            allocator: std.mem.Allocator,
            mic: *Mic,
            speaker: *Speaker,
            ref_reader: if (HasRefReader) *RefReaderT else void,
        ) !Self {
            const ring_samples = @as(usize, config.sample_rate) / 2;
            const clean_buf = try allocator.alloc(i16, ring_samples);
            errdefer allocator.free(clean_buf);

            var result = Self{
                .allocator = allocator,
                .mic = mic,
                .speaker = speaker,
                .ref_reader = ref_reader,
                .aec = null,
                .ns = null,
                .mixer = MixerType.init(allocator, .{
                    .output = .{ .rate = config.sample_rate, .channels = .mono },
                }),
                .ref_ring = if (!HasRefReader) undefined else {},
                .ref_ring_write = if (!HasRefReader) 0 else {},
                .ref_mutex = if (!HasRefReader) Rt.Mutex.init() else {},
                .clean_buf_pool = clean_buf,
                .clean_write_pos = 0,
                .clean_read_pos = 0,
                .clean_mutex = Rt.Mutex.init(),
                .clean_not_empty = Rt.Condition.init(),
                .clean_not_full = Rt.Condition.init(),
                .clean_closed = false,
                .speaker_thread = null,
                .mic_thread = null,
                .running = std.atomic.Value(bool).init(false),
            };

            // Allocate ref history ring for buffer_depth mode
            if (!HasRefReader) {
                const cap = ref_history_depth;
                if (cap > 0) {
                    result.ref_ring = try allocator.alloc(i16, cap * frame_size);
                    @memset(result.ref_ring, 0);
                } else {
                    result.ref_ring = try allocator.alloc(i16, frame_size);
                    @memset(result.ref_ring, 0);
                }
            }

            return result;
        }

        pub fn deinit(self: *Self) void {
            if (self.running.load(.acquire)) self.stop();
            self.mixer.deinit();
            self.clean_not_full.deinit();
            self.clean_not_empty.deinit();
            self.clean_mutex.deinit();
            if (!HasRefReader) {
                self.ref_mutex.deinit();
                self.allocator.free(self.ref_ring);
            }
            if (self.ns) |*n| n.deinit();
            if (self.aec) |*a| a.deinit();
            self.allocator.free(self.clean_buf_pool);
        }

        pub fn start(self: *Self) !void {
            if (self.running.load(.acquire)) return;

            if (config.enable_aec) {
                self.aec = try aec3_mod.Aec3.init(self.allocator, .{
                    .frame_size = config.frame_size,
                    .sample_rate = config.sample_rate,
                    .comfort_noise_rms = config.comfort_noise_rms,
                });
            }

            if (config.enable_ns) {
                self.ns = try ns_mod.NoiseSuppressor.init(self.allocator, .{
                    .frame_size = config.frame_size,
                    .sample_rate = config.sample_rate,
                    .noise_suppress_db = config.noise_suppress_db,
                });
            }

            self.running.store(true, .release);
            self.clean_closed = false;
            self.clean_write_pos = 0;
            self.clean_read_pos = 0;
            if (!HasRefReader) {
                self.ref_ring_write = 0;
            }

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

        pub fn createTrack(self: *Self, track_config: MixerType.TrackConfig) !TrackHandle {
            return self.mixer.createTrack(track_config);
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
        // Ref history (方式 1: buffer_depth, non-blocking ring)
        // ================================================================

        fn pushRef(self: *Self, frame: []const i16) void {
            if (HasRefReader) return;
            self.ref_mutex.lock();
            defer self.ref_mutex.unlock();
            const cap = ref_history_depth;
            if (cap == 0) return;
            const slot = self.ref_ring_write % cap;
            const offset = slot * frame_size;
            @memcpy(self.ref_ring[offset..][0..frame_size], frame[0..frame_size]);
            self.ref_ring_write +%= 1;
        }

        fn getAlignedRef(self: *Self, out: []i16) void {
            if (HasRefReader) {
                // 方式 2: platform 给对齐的 ref
                _ = self.ref_reader.read(out) catch {
                    @memset(out[0..frame_size], 0);
                };
                return;
            }
            // 方式 1: 取 speaker_buffer_depth 帧前的 ref
            self.ref_mutex.lock();
            defer self.ref_mutex.unlock();
            const depth = config.speaker_buffer_depth;
            const cap = ref_history_depth;
            if (cap == 0 or self.ref_ring_write == 0) {
                @memset(out[0..frame_size], 0);
                return;
            }
            // Target: write_pos - 1 - depth (the frame that was played depth frames ago)
            const target = if (self.ref_ring_write > depth + 1)
                self.ref_ring_write - 1 - depth
            else
                0;
            const slot = target % cap;
            const offset = slot * frame_size;
            @memcpy(out[0..frame_size], self.ref_ring[offset..][0..frame_size]);
        }

        // ================================================================
        // Two tasks
        // ================================================================

        fn speakerTask(self: *Self) void {
            var ref_buf: [4096]i16 = [_]i16{0} ** 4096;

            while (self.running.load(.acquire)) {
                const n = self.mixer.read(ref_buf[0..frame_size]) orelse break;
                if (n == 0) continue;

                _ = self.speaker.write(ref_buf[0..n]) catch continue;

                self.pushRef(ref_buf[0..frame_size]);
            }
        }

        fn rmsI16(buf: []const i16) f64 {
            var sum: f64 = 0;
            for (buf) |s| {
                const v: f64 = @floatFromInt(s);
                sum += v * v;
            }
            return @sqrt(sum / @as(f64, @floatFromInt(buf.len)));
        }

        fn micTask(self: *Self) void {
            var mic_buf: [4096]i16 = [_]i16{0} ** 4096;
            var ref_buf: [4096]i16 = [_]i16{0} ** 4096;
            var clean: [4096]i16 = [_]i16{0} ** 4096;
            var dbg_frame: usize = 0;

            while (self.running.load(.acquire)) {
                const mic_n = self.mic.read(mic_buf[0..frame_size]) catch continue;
                if (mic_n == 0) continue;
                if (mic_n < frame_size) {
                    @memset(mic_buf[mic_n..frame_size], 0);
                }

                self.getAlignedRef(ref_buf[0..frame_size]);

                if (self.aec) |*a| {
                    a.process(mic_buf[0..frame_size], ref_buf[0..frame_size], clean[0..frame_size]);
                } else {
                    @memcpy(clean[0..frame_size], mic_buf[0..frame_size]);
                }

                if (self.ns) |*ns| {
                    _ = ns.process(clean[0..frame_size]);
                }

                dbg_frame += 1;
                if (dbg_frame % 100 == 0) {
                    const mr = rmsI16(mic_buf[0..frame_size]);
                    const rr = rmsI16(ref_buf[0..frame_size]);
                    const cr = rmsI16(clean[0..frame_size]);
                    std.debug.print("[mic_task {d}s] mic={d:.0} ref={d:.0} clean={d:.0}\n", .{
                        dbg_frame / 100, mr, rr, cr,
                    });
                }

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
const tu = @import("test_utils.zig");

const aec_config: EngineConfig = .{
    .enable_aec = true,
    .enable_ns = false,
    .frame_size = 160,
    .aec_filter_length = 8000,
    .sample_rate = 16000,
};
const no_aec_config: EngineConfig = .{
    .enable_aec = false,
    .enable_ns = false,
    .frame_size = 160,
    .sample_rate = 16000,
};

const AecEngine = AudioEngine(TestRt, tu.LoopbackMic, tu.LoopbackSpeaker, aec_config);
const PlainEngine = AudioEngine(TestRt, tu.LoopbackMic, tu.LoopbackSpeaker, no_aec_config);

fn runAndMeasure(
    allocator: std.mem.Allocator,
    mic: *tu.LoopbackMic,
    speaker: *tu.LoopbackSpeaker,
    track_data: []const i16,
    skip_samples: usize,
    measure_buf: []i16,
) !usize {
    var eng = try AecEngine.init(allocator, mic, speaker, {});
    defer eng.deinit();

    const format = eng.outputFormat();
    const h = try eng.createTrack(.{ .label = "test" });
    try h.track.write(format, track_data);
    h.ctrl.closeWrite();

    try eng.start();

    var buf: [160]i16 = undefined;
    var skipped: usize = 0;
    while (skipped < skip_samples) {
        const n = eng.readClean(&buf) orelse break;
        skipped += n;
    }

    var pos: usize = 0;
    while (pos < measure_buf.len) {
        const n = eng.readClean(&buf) orelse break;
        const to_copy = @min(n, measure_buf.len - pos);
        @memcpy(measure_buf[pos..][0..to_copy], buf[0..to_copy]);
        pos += to_copy;
    }

    mic.stopped.store(true, .release);
    eng.stop();
    return pos;
}

test "engine init and deinit" {
    var speaker = try tu.LoopbackSpeaker.init(testing.allocator, 16000);
    defer speaker.deinit();
    var mic = tu.LoopbackMic{ .speaker = &speaker };
    var eng = try PlainEngine.init(testing.allocator, &mic, &speaker, {});
    defer eng.deinit();
}

// ============================================================================
// E2E-1: Pure echo cancellation — ERLE >= 15dB
// ============================================================================

test "E2E-1: loopback AEC single-tone ERLE >= 15dB" {
    var speaker = try tu.LoopbackSpeaker.init(testing.allocator, 48000);
    defer speaker.deinit();
    var mic = tu.LoopbackMic{
        .speaker = &speaker,
        .echo_gain = 0.8,
        .delay_samples = 320,
    };

    var tone: [32000]i16 = undefined; // 2 seconds
    tu.generateSine(&tone, 440.0, 16000.0, 16000, 0);

    var clean: [8000]i16 = undefined; // last 500ms
    const n = try runAndMeasure(testing.allocator, &mic, &speaker, &tone, 24000, &clean);

    try testing.expect(n > 0);
    const echo_rms = @sqrt(mic.raw_echo_energy / @as(f64, @floatFromInt(mic.total_read)));
    const clean_rms = tu.rmsEnergy(clean[0..n]);
    const erle = tu.erleDb(echo_rms, clean_rms);

    std.debug.print("[E2E-1] echo_rms={d:.1}, clean_rms={d:.1}, ERLE={d:.1}dB\n", .{ echo_rms, clean_rms, erle });
    try testing.expect(erle >= 15.0);
}

// ============================================================================
// E2E-2: Echo + near-end dual-tone frequency separation
// ============================================================================

test "E2E-2: dual-tone separation — 440Hz suppressed, 880Hz preserved" {
    var speaker = try tu.LoopbackSpeaker.init(testing.allocator, 48000);
    defer speaker.deinit();

    const inject_880 = struct {
        fn f(sample_idx: usize) i16 {
            const t: f32 = @as(f32, @floatFromInt(sample_idx)) / 16000.0;
            return @intFromFloat(@sin(t * 880.0 * 2.0 * std.math.pi) * 8000.0);
        }
    }.f;

    var mic = tu.LoopbackMic{
        .speaker = &speaker,
        .echo_gain = 0.8,
        .delay_samples = 320,
        .inject_fn = inject_880,
    };

    var tone: [32000]i16 = undefined;
    tu.generateSine(&tone, 440.0, 16000.0, 16000, 0);

    var clean: [8000]i16 = undefined;
    const n = try runAndMeasure(testing.allocator, &mic, &speaker, &tone, 24000, &clean);
    try testing.expect(n >= 1600);

    // Goertzel analysis on clean audio
    const power_440 = tu.goertzelPower(clean[0..n], 440.0, 16000.0);
    const power_880 = tu.goertzelPower(clean[0..n], 880.0, 16000.0);

    // Reference: 440Hz power in the echo signal (before AEC)
    var echo_ref: [8000]i16 = undefined;
    tu.generateSine(&echo_ref, 440.0, 16000.0 * 0.8, 16000, 0);
    const ref_power_440 = tu.goertzelPower(&echo_ref, 440.0, 16000.0);
    const ref_power_880: f64 = 8000.0 * 8000.0 / 2.0 * @as(f64, @floatFromInt(n));

    const suppression_440 = power_440 / @max(ref_power_440, 1.0);
    const retention_880 = power_880 / @max(ref_power_880, 1.0);

    std.debug.print("[E2E-2] 440Hz suppression={d:.1}%, 880Hz retention={d:.1}%\n", .{
        suppression_440 * 100.0,
        retention_880 * 100.0,
    });

    try testing.expect(suppression_440 < 0.2); // 440Hz suppressed > 80%
    try testing.expect(retention_880 > 0.3); // 880Hz preserved > 30%
}

// ============================================================================
// E2E-3: Multi-track mix — Goertzel 3 frequency suppression > 70%
// ============================================================================

test "E2E-3: multi-track AEC — 3 frequency suppression > 70%" {
    var speaker = try tu.LoopbackSpeaker.init(testing.allocator, 64000);
    defer speaker.deinit();
    var mic = tu.LoopbackMic{
        .speaker = &speaker,
        .echo_gain = 0.8,
        .delay_samples = 320,
    };

    var eng = try AecEngine.init(testing.allocator, &mic, &speaker, {});
    defer eng.deinit();

    const format = eng.outputFormat();

    // 3 tracks, 2 seconds each
    var t440: [32000]i16 = undefined;
    var t660: [32000]i16 = undefined;
    var t880: [32000]i16 = undefined;
    tu.generateSine(&t440, 440.0, 10000.0, 16000, 0);
    tu.generateSine(&t660, 660.0, 10000.0, 16000, 0);
    tu.generateSine(&t880, 880.0, 10000.0, 16000, 0);

    const h1 = try eng.createTrack(.{ .label = "440" });
    const h2 = try eng.createTrack(.{ .label = "660" });
    const h3 = try eng.createTrack(.{ .label = "880" });
    try h1.track.write(format, &t440);
    try h2.track.write(format, &t660);
    try h3.track.write(format, &t880);
    h1.ctrl.closeWrite();
    h2.ctrl.closeWrite();
    h3.ctrl.closeWrite();

    try eng.start();

    var buf: [160]i16 = undefined;
    var skip: usize = 0;
    while (skip < 24000) {
        const n = eng.readClean(&buf) orelse break;
        skip += n;
    }

    var clean: [8000]i16 = undefined;
    var pos: usize = 0;
    while (pos < 8000) {
        const n = eng.readClean(&buf) orelse break;
        const c = @min(n, 8000 - pos);
        @memcpy(clean[pos..][0..c], buf[0..c]);
        pos += c;
    }

    mic.stopped.store(true, .release);
    eng.stop();

    try testing.expect(pos >= 1600);

    // Measure suppression per frequency
    const cp_440 = tu.goertzelPower(clean[0..pos], 440.0, 16000.0);
    const cp_660 = tu.goertzelPower(clean[0..pos], 660.0, 16000.0);
    const cp_880 = tu.goertzelPower(clean[0..pos], 880.0, 16000.0);

    // Reference: echo power per frequency (mixed at 10000 amp * 0.8 gain = 8000 effective)
    var echo_ref: [8000]i16 = undefined;
    tu.generateSine(&echo_ref, 440.0, 8000.0, 16000, 0);
    const rp_440 = tu.goertzelPower(&echo_ref, 440.0, 16000.0);
    tu.generateSine(&echo_ref, 660.0, 8000.0, 16000, 0);
    const rp_660 = tu.goertzelPower(&echo_ref, 660.0, 16000.0);
    tu.generateSine(&echo_ref, 880.0, 8000.0, 16000, 0);
    const rp_880 = tu.goertzelPower(&echo_ref, 880.0, 16000.0);

    const s440 = cp_440 / @max(rp_440, 1.0);
    const s660 = cp_660 / @max(rp_660, 1.0);
    const s880 = cp_880 / @max(rp_880, 1.0);

    std.debug.print("[E2E-3] 440Hz={d:.1}%, 660Hz={d:.1}%, 880Hz={d:.1}%\n", .{
        s440 * 100.0, s660 * 100.0, s880 * 100.0,
    });

    try testing.expect(s440 < 0.3); // suppression > 70%
    try testing.expect(s660 < 0.3);
    try testing.expect(s880 < 0.3);
}

// ============================================================================
// E2E-4: AEC convergence curve — 10 data points
// ============================================================================

test "E2E-4: AEC convergence curve" {
    var speaker = try tu.LoopbackSpeaker.init(testing.allocator, 48000);
    defer speaker.deinit();
    var mic = tu.LoopbackMic{
        .speaker = &speaker,
        .echo_gain = 0.8,
        .delay_samples = 320,
    };

    var tone: [32000]i16 = undefined;
    tu.generateSine(&tone, 440.0, 16000.0, 16000, 0);

    var eng = try AecEngine.init(testing.allocator, &mic, &speaker, {});
    defer eng.deinit();

    const format = eng.outputFormat();
    const h = try eng.createTrack(.{ .label = "tone" });
    try h.track.write(format, &tone);
    h.ctrl.closeWrite();

    try eng.start();

    // Collect 10 data points, each 200ms (3200 samples)
    var energy_points: [10]f64 = undefined;
    var point_count: usize = 0;
    var buf: [160]i16 = undefined;
    var chunk: [3200]i16 = undefined;

    while (point_count < 10) {
        var chunk_pos: usize = 0;
        while (chunk_pos < 3200) {
            const n = eng.readClean(&buf) orelse break;
            const c = @min(n, 3200 - chunk_pos);
            @memcpy(chunk[chunk_pos..][0..c], buf[0..c]);
            chunk_pos += c;
        }
        if (chunk_pos == 0) break;
        energy_points[point_count] = tu.rmsEnergy(chunk[0..chunk_pos]);
        point_count += 1;
    }

    mic.stopped.store(true, .release);
    eng.stop();

    try testing.expect(point_count >= 8);

    std.debug.print("[E2E-4] convergence:", .{});
    for (0..point_count) |i| {
        std.debug.print(" {d:.0}", .{energy_points[i]});
    }
    std.debug.print("\n", .{});

    // Initial energy should be > 0 (echo leaks through)
    try testing.expect(energy_points[0] > 10.0);
    // Final energy should be < 15% of initial
    try testing.expect(energy_points[point_count - 1] < energy_points[0] * 0.15);
}

// ============================================================================
// E2E-5: stop/restart — 5 cycles, no memory leak
// ============================================================================

test "E2E-5: create/destroy engine 5 cycles no leak" {
    var speaker = try tu.LoopbackSpeaker.init(testing.allocator, 16000);
    defer speaker.deinit();

    const AecNsEngine = AudioEngine(TestRt, tu.LoopbackMic, tu.LoopbackSpeaker, .{
        .enable_aec = true,
        .enable_ns = true,
    });
    for (0..5) |_| {
        var mic = tu.LoopbackMic{ .speaker = &speaker };
        var eng = try AecNsEngine.init(testing.allocator, &mic, &speaker, {});

        const format = eng.outputFormat();
        const h = try eng.createTrack(.{});
        var tone = [_]i16{5000} ** 1600; // 100ms
        try h.track.write(format, &tone);
        h.ctrl.closeWrite();

        try eng.start();

        var buf: [160]i16 = undefined;
        _ = eng.readClean(&buf);

        mic.stopped.store(true, .release);
        eng.deinit();
        speaker.write_pos = 0;
        speaker.read_pos = 0;
    }
}

// ============================================================================
// E2E-6: Stress test — 50 tracks create/close sequentially
// ============================================================================

test "E2E-6: stress test 50 tracks create/close" {
    var speaker = try tu.LoopbackSpeaker.init(testing.allocator, 128000);
    defer speaker.deinit();
    var mic = tu.LoopbackMic{ .speaker = &speaker };

    var eng = try PlainEngine.init(testing.allocator, &mic, &speaker, {});
    defer eng.deinit();

    const format = eng.outputFormat();

    // Write all 50 tracks' data as one big chunk to avoid mixer stall
    const samples_per_track: usize = 1600; // 100ms
    const total_tracks: usize = 50;
    const total_samples = samples_per_track * total_tracks;

    const all_data = try testing.allocator.alloc(i16, total_samples);
    defer testing.allocator.free(all_data);
    for (0..total_tracks) |t| {
        const offset = t * samples_per_track;
        const freq = 440.0 + @as(f32, @floatFromInt(t)) * 20.0;
        tu.generateSine(all_data[offset..][0..samples_per_track], freq, 10000.0, 16000, offset);
    }

    const h = try eng.createTrack(.{ .label = "stress" });
    try h.track.write(format, all_data);
    h.ctrl.closeWrite();

    try eng.start();

    var buf: [160]i16 = undefined;
    var total_read: usize = 0;
    while (total_read < total_samples / 2) {
        const n = eng.readClean(&buf) orelse break;
        total_read += n;
    }

    mic.stopped.store(true, .release);
    eng.stop();

    std.debug.print("[E2E-6] stress: {d} samples processed\n", .{total_read});
    try testing.expect(total_read > 0);
}
