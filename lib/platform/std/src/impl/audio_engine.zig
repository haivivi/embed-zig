//! PortAudio blocking-mode audio I/O for std platform.
//!
//! DuplexAudio uses a SINGLE dedicated I/O thread to drive one duplex stream:
//!   write one frame to speaker -> read one frame from mic
//!
//! Public Mic/Speaker APIs are queue-based wrappers:
//! - Speaker.write() enqueues playback samples (blocking when full)
//! - Mic.read() dequeues captured samples (blocking when empty)
//!
//! This avoids concurrent `Pa_ReadStream` / `Pa_WriteStream` on the same stream,
//! which can cause jitter/clicks on some hosts when called from different threads.

const std = @import("std");
const pa = @import("portaudio");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: usize = 160;

// ~160ms @ 16k mono (16 frames)
const QUEUE_CAP: usize = FRAME_SIZE * 16;
const REF_CAP: usize = FRAME_SIZE * 256;

pub const DuplexAudio = struct {
    stream: pa.Stream,
    allocator: std.mem.Allocator,

    io_thread: ?std.Thread,
    running: bool,

    // Shared queue lock/conds
    q_mutex: std.Thread.Mutex,
    spk_not_full: std.Thread.Condition,
    mic_not_empty: std.Thread.Condition,

    // Speaker queue (app -> io thread)
    spk_ring: [QUEUE_CAP]i16,
    spk_write: usize,
    spk_read: usize,

    // Mic queue (io thread -> app)
    mic_ring: [QUEUE_CAP]i16,
    mic_write: usize,
    mic_read: usize,

    // Reference ring (played speaker frames)
    ref_ring: [REF_CAP]i16,
    ref_write: usize,
    ref_delay_samples: usize,

    pub fn init(allocator: std.mem.Allocator) !DuplexAudio {
        const input_device = readDeviceEnv(allocator, "AUDIO_INPUT_DEVICE");
        const output_device = readDeviceEnv(allocator, "AUDIO_OUTPUT_DEVICE");

        var stream_cfg = pa.StreamConfig{
            .input_channels = 1,
            .output_channels = 1,
            .sample_rate = @floatFromInt(SAMPLE_RATE),
            .frames_per_buffer = FRAME_SIZE,
        };
        if (input_device) |idx| stream_cfg.input_device = idx;
        if (output_device) |idx| stream_cfg.output_device = idx;

        logSelectedDevice("input", stream_cfg.input_device orelse pa.defaultInputDevice());
        logSelectedDevice("output", stream_cfg.output_device orelse pa.defaultOutputDevice());

        var stream = try pa.Stream.open(allocator, stream_cfg);
        errdefer stream.close();
        try stream.start();

        const auto_delay_samples = computeAutoRefDelaySamples(&stream);
        const env_delay_samples = readRefDelayEnv(allocator);
        const requested_delay_samples = env_delay_samples orelse auto_delay_samples;
        const max_delay_samples = REF_CAP - FRAME_SIZE;
        const ref_delay_samples = @min(requested_delay_samples, max_delay_samples);

        if (stream.info()) |si| {
            std.debug.print(
                "[duplex] pa latency in={d:.2}ms out={d:.2}ms -> ref_delay={d} samples ({d} frames){s}\n",
                .{
                    si.input_latency * 1000.0,
                    si.output_latency * 1000.0,
                    ref_delay_samples,
                    ref_delay_samples / FRAME_SIZE,
                    if (requested_delay_samples > max_delay_samples) " (clamped)" else "",
                },
            );
        } else {
            std.debug.print(
                "[duplex] ref_delay={d} samples ({d} frames){s}\n",
                .{
                    ref_delay_samples,
                    ref_delay_samples / FRAME_SIZE,
                    if (requested_delay_samples > max_delay_samples) " (clamped)" else "",
                },
            );
        }

        return DuplexAudio{
            .stream = stream,
            .allocator = allocator,
            .io_thread = null,
            .running = false,
            .q_mutex = .{},
            .spk_not_full = .{},
            .mic_not_empty = .{},
            .spk_ring = [_]i16{0} ** QUEUE_CAP,
            .spk_write = 0,
            .spk_read = 0,
            .mic_ring = [_]i16{0} ** QUEUE_CAP,
            .mic_write = 0,
            .mic_read = 0,
            .ref_ring = [_]i16{0} ** REF_CAP,
            .ref_write = 0,
            .ref_delay_samples = ref_delay_samples,
        };
    }

    fn computeAutoRefDelaySamples(stream: *pa.Stream) usize {
        const si = stream.info() orelse return 0;
        // For echo-reference alignment in app space, using output latency is
        // empirically more stable than input+output on macOS/CoreAudio.
        // (input latency can be very large and may over-shift ref outside AEC window)
        if (si.output_latency <= 0) return 0;
        const samples_f = si.output_latency * @as(f64, @floatFromInt(SAMPLE_RATE));
        if (samples_f <= 0) return 0;
        return @intFromFloat(@round(samples_f));
    }

    fn readRefDelayEnv(allocator: std.mem.Allocator) ?usize {
        if (readUsizeEnv(allocator, "AUDIO_REF_DELAY_SAMPLES")) |samples| {
            return samples;
        }
        if (readUsizeEnv(allocator, "AUDIO_REF_DELAY_FRAMES")) |frames| {
            return frames * FRAME_SIZE;
        }
        return null;
    }

    fn readUsizeEnv(allocator: std.mem.Allocator, name: []const u8) ?usize {
        const raw = std.process.getEnvVarOwned(allocator, name) catch return null;
        defer allocator.free(raw);

        const parsed = std.fmt.parseInt(i64, raw, 10) catch {
            std.debug.print("[duplex] ignore invalid env {s}={s}\n", .{ name, raw });
            return null;
        };
        if (parsed < 0) {
            std.debug.print("[duplex] ignore negative env {s}={d}\n", .{ name, parsed });
            return null;
        }
        return @intCast(parsed);
    }

    fn readDeviceEnv(allocator: std.mem.Allocator, name: []const u8) ?pa.DeviceIndex {
        const raw = std.process.getEnvVarOwned(allocator, name) catch return null;
        defer allocator.free(raw);

        const idx = std.fmt.parseInt(i32, raw, 10) catch {
            std.debug.print("[duplex] ignore invalid env {s}={s}\n", .{ name, raw });
            return null;
        };
        if (idx < 0) {
            std.debug.print("[duplex] ignore negative env {s}={d}\n", .{ name, idx });
            return null;
        }
        return @intCast(idx);
    }

    fn logSelectedDevice(kind: []const u8, idx: pa.DeviceIndex) void {
        if (pa.deviceInfo(idx)) |info| {
            std.debug.print("[duplex] {s} device #{d}: {s}\n", .{ kind, idx, info.name });
            return;
        }
        std.debug.print("[duplex] {s} device #{d}: <unknown>\n", .{ kind, idx });
    }

    pub fn start(self: *DuplexAudio) !void {
        self.q_mutex.lock();
        defer self.q_mutex.unlock();
        if (self.io_thread != null) return;
        self.running = true;
        self.io_thread = try std.Thread.spawn(.{}, ioLoop, .{self});
    }

    pub fn stop(self: *DuplexAudio) void {
        self.q_mutex.lock();
        self.running = false;
        self.spk_not_full.broadcast();
        self.mic_not_empty.broadcast();
        self.q_mutex.unlock();

        // Break a potentially blocking Pa_ReadStream/Pa_WriteStream in ioLoop.
        self.stream.abort();

        if (self.io_thread) |t| {
            t.join();
            self.io_thread = null;
        }

        self.stream.close();
    }

    fn spkAvailable(self: *const DuplexAudio) usize {
        return (self.spk_write + QUEUE_CAP - self.spk_read) % QUEUE_CAP;
    }

    fn spkSpace(self: *const DuplexAudio) usize {
        return QUEUE_CAP - 1 - self.spkAvailable();
    }

    fn micAvailable(self: *const DuplexAudio) usize {
        return (self.mic_write + QUEUE_CAP - self.mic_read) % QUEUE_CAP;
    }

    fn micSpace(self: *const DuplexAudio) usize {
        return QUEUE_CAP - 1 - self.micAvailable();
    }

    fn enqueueMicOverwrite(self: *DuplexAudio, data: []const i16) void {
        for (data) |s| {
            if (self.micSpace() == 0) {
                self.mic_read = (self.mic_read + 1) % QUEUE_CAP; // drop oldest
            }
            self.mic_ring[self.mic_write] = s;
            self.mic_write = (self.mic_write + 1) % QUEUE_CAP;
        }
        self.mic_not_empty.signal();
    }

    fn recordRef(self: *DuplexAudio, data: []const i16) void {
        for (data) |s| {
            self.ref_ring[self.ref_write % REF_CAP] = s;
            self.ref_write += 1;
        }
    }

    fn ioLoop(self: *DuplexAudio) void {
        var out_frame: [FRAME_SIZE]i16 = [_]i16{0} ** FRAME_SIZE;
        var in_frame: [FRAME_SIZE]i16 = [_]i16{0} ** FRAME_SIZE;
        var dbg_frame: usize = 0;

        while (true) {
            // 1) Pull one speaker frame from queue (non-blocking, silence fallback)
            self.q_mutex.lock();
            if (!self.running) {
                self.q_mutex.unlock();
                break;
            }

            const avail = self.spkAvailable();
            const n = @min(avail, FRAME_SIZE);
            if (n > 0) {
                for (0..n) |i| {
                    out_frame[i] = self.spk_ring[(self.spk_read + i) % QUEUE_CAP];
                }
                self.spk_read = (self.spk_read + n) % QUEUE_CAP;
                self.spk_not_full.signal();
            }
            self.q_mutex.unlock();

            if (n < FRAME_SIZE) {
                @memset(out_frame[n..FRAME_SIZE], 0);
            }

            // 2) Hardware paced write + blocking read (single thread, same stream)
            // stop() calls stream.abort() to break blocking I/O during shutdown.
            _ = self.stream.write(out_frame[0..FRAME_SIZE]) catch continue;
            const rn = self.stream.read(in_frame[0..FRAME_SIZE]) catch 0;
            if (rn < FRAME_SIZE) @memset(in_frame[rn..FRAME_SIZE], 0);

            dbg_frame += 1;
            if (dbg_frame % 100 == 0) {
                std.debug.print("[duplex_io {d}s] out_peak={d} in_peak={d}\n", .{
                    dbg_frame / 100,
                    absPeakI16(out_frame[0..FRAME_SIZE]),
                    absPeakI16(in_frame[0..FRAME_SIZE]),
                });
            }

            // 3) Publish mic and ref
            self.q_mutex.lock();
            if (!self.running) {
                self.q_mutex.unlock();
                break;
            }
            self.enqueueMicOverwrite(in_frame[0..FRAME_SIZE]);
            self.recordRef(out_frame[0..FRAME_SIZE]);
            self.q_mutex.unlock();
        }
    }

    fn absPeakI16(buf: []const i16) u16 {
        var peak: u16 = 0;
        for (buf) |s| {
            const a: u16 = if (s == std.math.minInt(i16))
                @intCast(std.math.maxInt(i16))
            else
                @abs(s);
            if (a > peak) peak = a;
        }
        return peak;
    }

    pub const Mic = struct {
        parent: *DuplexAudio,

        pub fn read(self: *Mic, buf: []i16) !usize {
            self.parent.q_mutex.lock();
            defer self.parent.q_mutex.unlock();

            while (self.parent.running and self.parent.micAvailable() == 0) {
                self.parent.mic_not_empty.wait(&self.parent.q_mutex);
            }

            const avail = self.parent.micAvailable();
            if (avail == 0 and !self.parent.running) return 0;

            const n = @min(buf.len, avail);
            for (0..n) |i| {
                buf[i] = self.parent.mic_ring[(self.parent.mic_read + i) % QUEUE_CAP];
            }
            self.parent.mic_read = (self.parent.mic_read + n) % QUEUE_CAP;
            return n;
        }
    };

    pub const Speaker = struct {
        parent: *DuplexAudio,

        pub fn write(self: *Speaker, buf: []const i16) !usize {
            self.parent.q_mutex.lock();
            defer self.parent.q_mutex.unlock();

            var offset: usize = 0;
            while (offset < buf.len) {
                while (self.parent.running and self.parent.spkSpace() == 0) {
                    self.parent.spk_not_full.wait(&self.parent.q_mutex);
                }
                if (!self.parent.running) return offset;

                const space = self.parent.spkSpace();
                const n = @min(space, buf.len - offset);
                for (0..n) |i| {
                    self.parent.spk_ring[(self.parent.spk_write + i) % QUEUE_CAP] = buf[offset + i];
                }
                self.parent.spk_write = (self.parent.spk_write + n) % QUEUE_CAP;
                offset += n;
            }

            return offset;
        }

        pub fn setVolume(_: *Speaker, _: u8) !void {}
    };

    pub const RefReader = struct {
        parent: *DuplexAudio,

        pub fn read(self: *RefReader, buf: []i16) !usize {
            self.parent.q_mutex.lock();
            defer self.parent.q_mutex.unlock();

            const n = @min(buf.len, FRAME_SIZE);
            const needed = n + self.parent.ref_delay_samples;
            if (self.parent.ref_write < needed) {
                @memset(buf[0..n], 0);
                return n;
            }

            const start_idx = self.parent.ref_write - needed;
            for (0..n) |i| {
                buf[i] = self.parent.ref_ring[(start_idx + i) % REF_CAP];
            }
            return n;
        }
    };

    pub fn mic(self: *DuplexAudio) Mic {
        return .{ .parent = self };
    }

    pub fn speaker(self: *DuplexAudio) Speaker {
        return .{ .parent = self };
    }

    pub fn refReader(self: *DuplexAudio) RefReader {
        return .{ .parent = self };
    }

    pub fn getRefOffset(_: *DuplexAudio) i32 {
        return 0;
    }
};
