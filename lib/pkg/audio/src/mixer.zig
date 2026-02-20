//! Mixer — multi-track audio mixer
//!
//! Mixes multiple audio tracks into a single output stream. Each track can have
//! independent gain, label, and input format (with automatic resampling).
//!
//! Port of giztoy's Go pcm.Mixer and Rust pcm::mixer::Mixer.
//!
//! ## Architecture
//!
//! - **Track.write()** blocks if ring buffer is full (backpressure)
//! - **Mixer.read()** reads from each track non-blocking; only blocks when
//!   no track has any data available
//! - Per-track resampler converts input format to mixer output format on the
//!   read path (matching Go architecture)
//! - f32 intermediate mixing with clipping to i16 output
//!
//! ## Usage
//!
//! ```zig
//! const Rt = @import("std_impl").runtime;
//! const Mx = Mixer(Rt);
//!
//! var mx = Mx.init(allocator, .{ .output = .{ .rate = 16000 } });
//! defer mx.deinit();
//!
//! const h = try mx.createTrack(.{ .label = "tts" });
//! // Writer thread: h.track.write(format, &samples);
//! // Reader thread: while (mx.read(&buf)) |n| { ... }
//! ```

const std = @import("std");
const trait = @import("trait");
const resampler_mod = @import("resampler.zig");

const Allocator = std.mem.Allocator;
const Resampler = resampler_mod.Resampler;

pub fn Mixer(comptime Rt: type) type {
    comptime {
        _ = trait.sync.Mutex(Rt.Mutex);
        _ = trait.sync.Condition(Rt.Condition, Rt.Mutex);
    }

    return struct {
        const Self = @This();

        pub const Format = resampler_mod.Format;

        pub const Config = struct {
            output: Format,
            auto_close: bool = false,
            silence_gap_ms: u32 = 0,
            on_track_created: ?*const fn () void = null,
            on_track_closed: ?*const fn () void = null,
        };

        pub const TrackConfig = struct {
            label: []const u8 = "",
            gain: f32 = 1.0,
        };

        pub const TrackHandle = struct {
            track: *Track,
            ctrl: *TrackCtrl,
        };

        // ================================================================
        // Mixer state
        // ================================================================

        allocator: Allocator,
        config: Config,

        mutex: Rt.Mutex,
        track_available: Rt.Condition,
        data_available: Rt.Condition,

        head: ?*TrackCtrl,
        detached_head: ?*TrackCtrl,
        close_write: bool,
        close_err: bool,

        running_silence_ms: u32,

        mix_buf: []f32,
        read_chunk_samples: usize,

        // ================================================================
        // Lifecycle
        // ================================================================

        pub fn init(allocator: Allocator, config: Config) Self {
            const bytes_per_sample: usize = @as(usize, @intFromEnum(config.output.channels)) * 2;
            const bytes_per_sec: usize = @as(usize, config.output.rate) * bytes_per_sample;
            const chunk_bytes: usize = bytes_per_sec * 60 / 1000; // 60ms
            const chunk_samples = chunk_bytes / 2;

            return .{
                .allocator = allocator,
                .config = config,
                .mutex = Rt.Mutex.init(),
                .track_available = Rt.Condition.init(),
                .data_available = Rt.Condition.init(),
                .head = null,
                .detached_head = null,
                .close_write = false,
                .close_err = false,
                .running_silence_ms = if (config.silence_gap_ms > 0) config.silence_gap_ms else 0,
                .mix_buf = allocator.alloc(f32, chunk_samples) catch &.{},
                .read_chunk_samples = chunk_samples,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free all remaining active tracks
            var it = self.head;
            while (it) |ctrl| {
                const next = ctrl.next;
                self.freeTrackCtrl(ctrl);
                it = next;
            }
            self.head = null;

            // Free detached tracks (removed during read)
            var dit = self.detached_head;
            while (dit) |ctrl| {
                const next = ctrl.next;
                self.allocator.destroy(ctrl);
                dit = next;
            }
            self.detached_head = null;

            if (self.mix_buf.len > 0) {
                self.allocator.free(self.mix_buf);
            }
            self.data_available.deinit();
            self.track_available.deinit();
            self.mutex.deinit();
        }

        // ================================================================
        // Output (reader side)
        // ================================================================

        /// Read mixed audio into buf. Blocks until data available.
        /// Returns number of i16 samples written, null on EOF/error.
        pub fn read(self: *Self, buf: []i16) ?usize {
            const limit = @min(buf.len, self.read_chunk_samples);
            if (limit == 0) return 0;

            self.mutex.lock();
            defer self.mutex.unlock();

            // Ensure mix buffer is large enough
            if (self.mix_buf.len < limit) {
                if (self.mix_buf.len > 0) self.allocator.free(self.mix_buf);
                self.mix_buf = self.allocator.alloc(f32, limit) catch return null;
            }

            var peak: f32 = 0;
            var has_data = false;
            var is_silence = false;

            while (true) {
                const result = self.readFullLocked(buf[0..limit]);
                peak = result.peak;
                has_data = result.has_data;
                is_silence = result.is_silence;

                if (result.is_eof) return null;
                if (has_data or is_silence) break;

                // No data from any track — wait
                self.data_available.wait(&self.mutex);
            }

            // Update running silence
            if (has_data) {
                self.running_silence_ms = 0;
            } else if (is_silence) {
                const chunk_duration_ms = self.chunkDurationMs(limit);
                self.running_silence_ms += chunk_duration_ms;
            }

            // Convert f32 mix buffer to i16 output
            if (peak == 0) {
                @memset(buf[0..limit], 0);
            } else {
                for (0..limit) |i| {
                    var t = self.mix_buf[i];
                    if (t > 1) t = 1 else if (t < -1) t = -1;
                    buf[i] = if (t >= 0)
                        @intFromFloat(t * 32767)
                    else
                        @intFromFloat(t * 32768);
                }
            }

            return limit;
        }

        const ReadResult = struct {
            peak: f32,
            has_data: bool,
            is_silence: bool,
            is_eof: bool,
        };

        /// Core mixing loop. Called with mutex held.
        fn readFullLocked(self: *Self, buf: []i16) ReadResult {
            // Get head track, handling empty states
            const head_result = self.headTrackLocked();
            if (head_result.is_eof) return .{ .peak = 0, .has_data = false, .is_silence = false, .is_eof = true };
            if (head_result.is_silence) return .{ .peak = 0, .has_data = false, .is_silence = true, .is_eof = false };

            // Clear mix buffer
            for (self.mix_buf[0..buf.len]) |*s| s.* = 0;

            // Temporary buffer for reading each track (i16-aligned)
            const track_i16 = self.allocator.alloc(i16, buf.len) catch
                return .{ .peak = 0, .has_data = false, .is_silence = false, .is_eof = false };
            defer self.allocator.free(track_i16);
            const track_buf = std.mem.sliceAsBytes(track_i16);

            var peak: f32 = 0;
            var has_data = false;

            var prev: ?*TrackCtrl = null;
            var it = self.head;
            while (it) |ctrl| {
                const ok = ctrl.readFull(track_buf);

                if (ok.is_err or (ok.is_eof and !ok.has_data)) {
                    // Track errored or finished — unlink from list
                    // Don't free: user may still hold TrackCtrl reference.
                    // TrackInternal resources are freed, but TrackCtrl stays valid.
                    const next = ctrl.next;
                    if (prev) |p| {
                        p.next = next;
                    } else {
                        self.head = next;
                    }
                    // Move to detached list (freed by deinit)
                    ctrl.next = self.detached_head;
                    self.detached_head = ctrl;
                    // Free the internal track resources (ring buf, resampler)
                    if (ctrl.track) |t| {
                        t.deinit();
                        self.allocator.destroy(t);
                        ctrl.track = null;
                    }
                    if (self.config.on_track_closed) |cb| cb();
                    it = next;
                    continue;
                }

                if (ok.has_data) {
                    has_data = true;
                    const gain = ctrl.atomicLoadGain();
                    for (0..buf.len) |i| {
                        if (track_i16[i] != 0) {
                            var s: f32 = @floatFromInt(track_i16[i]);
                            s = if (s >= 0) s / 32767.0 else s / 32768.0;
                            s *= gain;
                            const abs_s = if (s >= 0) s else -s;
                            if (abs_s > peak) peak = abs_s;
                            self.mix_buf[i] += s;
                        }
                    }
                }

                prev = ctrl;
                it = ctrl.next;
            }

            // If all tracks were removed during iteration and no data was read,
            // re-check head state (may need to return EOF for auto_close/close_write).
            if (!has_data and self.head == null) {
                const recheck = self.headTrackLocked();
                if (recheck.is_eof) return .{ .peak = 0, .has_data = false, .is_silence = false, .is_eof = true };
                if (recheck.is_silence) return .{ .peak = 0, .has_data = false, .is_silence = true, .is_eof = false };
            }

            return .{ .peak = peak, .has_data = has_data, .is_silence = false, .is_eof = false };
        }

        const HeadResult = struct {
            is_silence: bool,
            is_eof: bool,
        };

        /// Returns state of the track list. Called with mutex held.
        /// Blocks (via condvar wait) if no tracks and waiting for one.
        fn headTrackLocked(self: *Self) HeadResult {
            while (true) {
                if (self.close_err) return .{ .is_silence = false, .is_eof = true };

                if (self.head != null) return .{ .is_silence = false, .is_eof = false };

                if (self.close_write) return .{ .is_silence = false, .is_eof = true };

                if (self.config.auto_close) {
                    self.closeWriteLocked();
                    return .{ .is_silence = false, .is_eof = true };
                }

                if (self.running_silence_ms < self.config.silence_gap_ms) {
                    return .{ .is_silence = true, .is_eof = false };
                }

                // Wait for a track to be created
                self.track_available.wait(&self.mutex);
            }
        }

        // ================================================================
        // Track management
        // ================================================================

        pub fn createTrack(self: *Self, config: TrackConfig) error{ Closed, OutOfMemory }!TrackHandle {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.close_err) return error.Closed;
            if (self.close_write) return error.Closed;

            const internal = try self.allocateTrackInternal();
            internal.* = TrackInternal.init(self);
            internal.track_handle = .{ .internal = internal };

            const ctrl = try self.allocator.create(TrackCtrl);
            ctrl.* = .{
                .track = internal,
                .next = self.head,
                .label = config.label,
            };
            ctrl.atomicStoreGain(config.gain);

            self.head = ctrl;

            self.track_available.signal();

            if (self.config.on_track_created) |cb| cb();

            return .{
                .track = &internal.track_handle,
                .ctrl = ctrl,
            };
        }

        /// Free a TrackCtrl that was returned by createTrack.
        /// Call after the track has been closed/drained and you no longer need
        /// to read readBytes/gain/label.
        pub fn destroyTrackCtrl(self: *Self, ctrl: *TrackCtrl) void {
            if (ctrl.track) |t| {
                t.deinit();
                self.allocator.destroy(t);
            }
            self.allocator.destroy(ctrl);
        }

        pub fn closeWrite(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closeWriteLocked();
        }

        fn closeWriteLocked(self: *Self) void {
            if (self.close_err) return;
            if (self.close_write) return;

            self.close_write = true;

            var it = self.head;
            while (it) |ctrl| {
                if (ctrl.track) |t| t.closeWriteInternal();
                it = ctrl.next;
            }

            self.track_available.broadcast();
            self.data_available.broadcast();
        }

        pub fn close(self: *Self) void {
            self.closeWithError();
        }

        pub fn closeWithError(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.close_err) return;
            self.close_err = true;

            if (!self.close_write) {
                self.close_write = true;
            }

            var it = self.head;
            while (it) |ctrl| {
                if (ctrl.track) |t| t.closeWithErrorInternal();
                it = ctrl.next;
            }

            self.track_available.broadcast();
            self.data_available.broadcast();
        }

        // ================================================================
        // Internal helpers
        // ================================================================

        fn notifyDataAvailable(self: *Self) void {
            self.data_available.signal();
        }

        fn allocateTrackInternal(self: *Self) !*TrackInternal {
            return self.allocator.create(TrackInternal);
        }

        fn freeTrackCtrl(self: *Self, ctrl: *TrackCtrl) void {
            if (ctrl.track) |t| {
                t.deinit();
                self.allocator.destroy(t);
                ctrl.track = null;
            }
            self.allocator.destroy(ctrl);
        }

        fn chunkDurationMs(self: *Self, sample_count: usize) u32 {
            const rate: u32 = self.config.output.rate;
            const channels: u32 = @intFromEnum(self.config.output.channels);
            const frames = @as(u32, @intCast(sample_count)) / channels;
            return (frames * 1000) / rate;
        }

        // ================================================================
        // Track (writer side)
        // ================================================================

        pub const Track = struct {
            internal: *TrackInternal,

            /// Write PCM samples in the given format. If format differs from
            /// the previous write, a new internal writer with a new resampler
            /// is created (matching Go's track.Write(chunk) behavior).
            /// Blocks if ring buffer is full (backpressure).
            pub fn write(self: *Track, format: Format, samples: []const i16) error{Closed}!void {
                try self.internal.write(format, samples);
            }
        };

        // ================================================================
        // TrackCtrl (control side)
        // ================================================================

        pub const TrackCtrl = struct {
            track: ?*TrackInternal,
            next: ?*TrackCtrl,
            label: []const u8,

            // Gain stored as u32 bits for atomic access (matches Go AtomicFloat32)
            gain_bits: u32 = @as(u32, @bitCast(@as(f32, 1.0))),

            // Read byte counter (atomic)
            read_bytes_val: i64 = 0,

            // Fade-out duration in ms (atomic)
            fade_out_ms_val: i32 = 0,

            pub fn setGain(self: *TrackCtrl, g: f32) void {
                self.atomicStoreGain(g);
            }

            pub fn getGain(self: *TrackCtrl) f32 {
                return self.atomicLoadGain();
            }

            pub fn getLabel(self: *TrackCtrl) []const u8 {
                return self.label;
            }

            pub fn readBytes(self: *TrackCtrl) i64 {
                return @atomicLoad(i64, &self.read_bytes_val, .acquire);
            }

            pub fn setFadeOutDuration(self: *TrackCtrl, ms: u32) void {
                @atomicStore(i32, &self.fade_out_ms_val, @intCast(ms), .release);
            }

            pub fn closeWrite(self: *TrackCtrl) void {
                const t = self.track orelse return;
                t.closeWriteInternal();
            }

            pub fn closeWriteWithSilence(self: *TrackCtrl, silence_ms: u32) void {
                const t = self.track orelse return;
                const output = t.mixer.config.output;
                const samples_per_ms = @as(usize, output.rate) * @as(usize, @intFromEnum(output.channels)) / 1000;
                const total_samples = samples_per_ms * silence_ms;

                // Write silence in chunks
                const zeros = [_]i16{0} ** 1024;
                var remaining = total_samples;
                while (remaining > 0) {
                    const chunk = @min(remaining, zeros.len);
                    t.write(output, zeros[0..chunk]) catch break;
                    remaining -= chunk;
                }
                self.closeWrite();
            }

            pub fn closeSelf(self: *TrackCtrl) void {
                const t = self.track orelse return;
                const fade_ms = @atomicLoad(i32, &self.fade_out_ms_val, .acquire);
                if (fade_ms > 0) {
                    self.setGainLinearTo(0, @intCast(fade_ms));
                }
                t.closeInternal();
            }

            pub fn closeWithError(self: *TrackCtrl) void {
                const t = self.track orelse return;
                const fade_ms = @atomicLoad(i32, &self.fade_out_ms_val, .acquire);
                if (fade_ms > 0) {
                    self.setGainLinearTo(0, @intCast(fade_ms));
                }
                t.closeWithErrorInternal();
            }

            /// Linear fade from current gain to target over duration_ms.
            /// Blocks until complete.
            pub fn setGainLinearTo(self: *TrackCtrl, to: f32, duration_ms: u32) void {
                const from = self.getGain();
                const interval_ms: u32 = 10;
                const steps = duration_ms / interval_ms;
                if (steps == 0) {
                    self.setGain(to);
                    return;
                }
                for (0..steps) |i| {
                    sleepMs(interval_ms);
                    const progress = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(steps));
                    self.setGain(from + (to - from) * progress);
                }
            }

            fn atomicLoadGain(self: *const TrackCtrl) f32 {
                const bits = @atomicLoad(u32, &@as(*const TrackCtrl, self).gain_bits, .acquire);
                return @bitCast(bits);
            }

            fn atomicStoreGain(self: *TrackCtrl, g: f32) void {
                @atomicStore(u32, &self.gain_bits, @bitCast(g), .release);
            }

            fn atomicAddReadBytes(self: *TrackCtrl, n: i64) void {
                _ = @atomicRmw(i64, &self.read_bytes_val, .Add, n, .acq_rel);
            }

            /// Read from the track, filling the buffer. Non-blocking per-track.
            fn readFull(self: *TrackCtrl, buf: []u8) struct { has_data: bool, is_err: bool, is_eof: bool } {
                const t = self.track orelse return .{ .has_data = false, .is_err = true, .is_eof = false };
                const result = trackReadFull(t, buf);
                if (result.bytes_read > 0) {
                    self.atomicAddReadBytes(@intCast(result.bytes_read));
                }
                return .{ .has_data = result.bytes_read > 0, .is_err = result.is_err, .is_eof = result.is_eof };
            }
        };

        // ================================================================
        // TrackInternal
        // ================================================================

        const TrackInternal = struct {
            mixer: *Self,
            track_handle: Track,

            mutex: Rt.Mutex,
            close_err: bool,
            close_write: bool,

            // Current writer (single writer, recreated on format change)
            current_writer: ?*TrackWriter,
            current_format: ?Format,

            fn init(mixer: *Self) TrackInternal {
                return .{
                    .mixer = mixer,
                    .track_handle = undefined, // set after
                    .mutex = Rt.Mutex.init(),
                    .close_err = false,
                    .close_write = false,
                    .current_writer = null,
                    .current_format = null,
                };
            }

            fn postInit(self: *TrackInternal) void {
                self.track_handle = .{ .internal = self };
            }

            fn deinit(self: *TrackInternal) void {
                if (self.current_writer) |w| {
                    w.deinit(self.mixer.allocator);
                    self.mixer.allocator.destroy(w);
                }
                self.mutex.deinit();
            }

            fn write(self: *TrackInternal, format: Format, samples: []const i16) error{Closed}!void {
                const writer = try self.getWriter(format);
                const bytes = std.mem.sliceAsBytes(samples);
                try writer.ring.writeFull(bytes);
            }

            fn getWriter(self: *TrackInternal, format: Format) error{Closed}!*TrackWriter {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.close_err) return error.Closed;

                if (self.current_format) |cf| {
                    if (Format.eql(cf, format)) {
                        return self.current_writer.?;
                    }
                    // Format changed — close old writer, create new one
                    if (self.current_writer) |w| {
                        w.ring.closeWriteRing();
                        w.deinit(self.mixer.allocator);
                        self.mixer.allocator.destroy(w);
                    }
                }

                const w = self.mixer.allocator.create(TrackWriter) catch return error.Closed;
                w.* = TrackWriter.init(self, format, self.mixer.allocator) catch {
                    self.mixer.allocator.destroy(w);
                    return error.Closed;
                };
                self.current_writer = w;
                self.current_format = format;
                return w;
            }

            /// Non-blocking read through resampler → ring buffer.
            fn readData(self: *TrackInternal, buf: []u8) struct { n: usize, is_err: bool, is_eof: bool } {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.close_err) return .{ .n = 0, .is_err = true, .is_eof = false };

                if (self.current_writer) |w| {
                    const rn = w.readNonBlocking(buf);
                    if (rn.n > 0) return .{ .n = rn.n, .is_err = false, .is_eof = false };
                    if (rn.is_eof) return .{ .n = 0, .is_err = false, .is_eof = true };
                    // No data but not EOF
                    return .{ .n = 0, .is_err = false, .is_eof = false };
                }

                // No writer yet
                if (self.close_write) return .{ .n = 0, .is_err = false, .is_eof = true };
                return .{ .n = 0, .is_err = false, .is_eof = false };
            }

            fn closeWriteInternal(self: *TrackInternal) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.close_write = true;
                if (self.current_writer) |w| {
                    w.ring.closeWriteRing();
                }
                self.mixer.notifyDataAvailable();
            }

            fn closeInternal(self: *TrackInternal) void {
                self.closeWithErrorInternal();
            }

            fn closeWithErrorInternal(self: *TrackInternal) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.close_err = true;
                self.close_write = true;
                if (self.current_writer) |w| {
                    w.ring.closeWithErrorRing();
                }
                self.mixer.notifyDataAvailable();
            }
        };

        // ================================================================
        // TrackWriter (input format + optional resampler + ring buffer)
        // ================================================================

        const TrackWriter = struct {
            ring: *RingBuf,
            rs: ?Resampler,
            input_format: Format,

            // Resampler work buffers for read path
            rs_in_buf: ?[]i16,
            rs_out_buf: ?[]i16,

            fn init(track: *TrackInternal, format: Format, allocator: Allocator) !TrackWriter {
                const output = track.mixer.config.output;
                const ring = try allocator.create(RingBuf);
                const buf_size = @as(usize, output.rate) * @as(usize, @intFromEnum(output.channels)) * 2 * 10; // 10 seconds
                ring.* = try RingBuf.init(track, allocator, buf_size);

                const needs_resample = format.rate != output.rate or format.channels != output.channels;
                var rs: ?Resampler = null;
                var rs_in_buf: ?[]i16 = null;
                var rs_out_buf: ?[]i16 = null;

                if (needs_resample) {
                    rs = try Resampler.init(allocator, .{
                        .channels = @intFromEnum(output.channels),
                        .in_rate = format.rate,
                        .out_rate = output.rate,
                        .quality = 3,
                    });
                    rs_in_buf = try allocator.alloc(i16, 4096);
                    rs_out_buf = try allocator.alloc(i16, 4096 * 6);
                }

                return .{
                    .ring = ring,
                    .rs = rs,
                    .input_format = format,
                    .rs_in_buf = rs_in_buf,
                    .rs_out_buf = rs_out_buf,
                };
            }

            fn deinit(self: *TrackWriter, allocator: Allocator) void {
                if (self.rs_out_buf) |b| allocator.free(b);
                if (self.rs_in_buf) |b| allocator.free(b);
                if (self.rs) |*rs| rs.deinit();
                self.ring.deinit(allocator);
                allocator.destroy(self.ring);
            }

            const ReadNBResult = struct { n: usize, is_eof: bool };

            /// Non-blocking read. If resampler is present, reads raw from
            /// ring buffer into resampler, then outputs resampled data.
            fn readNonBlocking(self: *TrackWriter, buf: []u8) ReadNBResult {
                if (self.rs) |*rs| {
                    return self.readWithResampler(rs, buf);
                }
                const r = self.ring.readNonBlocking(buf);
                return .{ .n = r.n, .is_eof = r.is_eof };
            }

            fn readWithResampler(self: *TrackWriter, rs: *Resampler, out_buf: []u8) ReadNBResult {
                const in_buf = self.rs_in_buf orelse return .{ .n = 0, .is_eof = false };
                const work_out = self.rs_out_buf orelse return .{ .n = 0, .is_eof = false };

                // Read raw input from ring buffer (non-blocking)
                const raw_bytes = std.mem.sliceAsBytes(in_buf);
                const ring_result = self.ring.readNonBlocking(raw_bytes);
                if (ring_result.n == 0) return .{ .n = 0, .is_eof = ring_result.is_eof };

                const in_samples = ring_result.n / 2;
                const max_out = @min(work_out.len, out_buf.len / 2);

                const result = rs.process(in_buf[0..in_samples], work_out[0..max_out]) catch
                    return .{ .n = 0, .is_eof = false };

                const out_bytes = result.out_produced * 2;
                const out_i16 = work_out[0..result.out_produced];
                const out_as_bytes = std.mem.sliceAsBytes(out_i16);
                @memcpy(out_buf[0..out_bytes], out_as_bytes);

                return .{ .n = out_bytes, .is_eof = false };
            }
        };

        // ================================================================
        // readFull helper — matches Go's readFull(r io.Reader, p []byte)
        // ================================================================

        /// Reads from track until buf is filled or no more data.
        /// Partial data is zero-padded. Returns 0 bytes_read if completely empty.
        fn trackReadFull(track: *TrackInternal, buf: []u8) struct { bytes_read: usize, is_err: bool, is_eof: bool } {
            // Zero-fill first (matching Go: for i := range p { p[i] = 0 })
            @memset(buf, 0);

            var total: usize = 0;
            var saw_eof = false;
            while (total < buf.len) {
                const result = track.readData(buf[total..]);
                if (result.is_err) return .{ .bytes_read = 0, .is_err = true, .is_eof = false };
                if (result.n == 0) {
                    if (result.is_eof) saw_eof = true;
                    break;
                }
                total += result.n;
            }

            if (total == 0) return .{ .bytes_read = 0, .is_err = false, .is_eof = saw_eof };

            // Partial fill — already zero-padded, return full buf length
            return .{ .bytes_read = buf.len, .is_err = false, .is_eof = false };
        }

        // ================================================================
        // RingBuf — per-track circular byte buffer
        // ================================================================

        const RingBuf = struct {
            track: *TrackInternal,

            not_full: Rt.Condition,
            mutex: Rt.Mutex,

            buf: []u8,
            head: usize,
            tail: usize,

            close_write: bool,
            close_err: bool,

            fn init(track: *TrackInternal, allocator: Allocator, size: usize) !RingBuf {
                const buf = try allocator.alloc(u8, size);
                return .{
                    .track = track,
                    .not_full = Rt.Condition.init(),
                    .mutex = Rt.Mutex.init(),
                    .buf = buf,
                    .head = 0,
                    .tail = 0,
                    .close_write = false,
                    .close_err = false,
                };
            }

            fn deinit(self: *RingBuf, allocator: Allocator) void {
                allocator.free(self.buf);
                self.not_full.deinit();
                self.mutex.deinit();
            }

            fn capacity(self: *const RingBuf) usize {
                return self.buf.len;
            }

            fn dataLen(self: *const RingBuf) usize {
                return self.tail - self.head;
            }

            /// Write all bytes, blocking if ring buffer is full.
            fn writeFull(self: *RingBuf, data: []const u8) error{Closed}!void {
                if (data.len == 0) return;

                self.mutex.lock();
                defer self.mutex.unlock();

                var p = data;
                while (p.len > 0) {
                    if (self.close_err) return error.Closed;
                    if (self.close_write) return error.Closed;

                    if (self.tail - self.head == self.buf.len) {
                        // Ring buffer full — block (wait atomically unlocks/relocks)
                        self.not_full.wait(&self.mutex);
                        continue;
                    }

                    const written = self.writeInternal(p);
                    p = p[written..];
                    // Notify mixer that data is available
                    self.track.mixer.notifyDataAvailable();
                }
            }

            const RingReadResult = struct { n: usize, is_eof: bool };

            /// Non-blocking read. Returns bytes read. Empty → (0, false).
            fn readNonBlocking(self: *RingBuf, buf: []u8) RingReadResult {
                @memset(buf, 0);

                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.close_err) return .{ .n = 0, .is_eof = true };

                if (self.head == self.tail) {
                    if (self.close_write) return .{ .n = 0, .is_eof = true };
                    return .{ .n = 0, .is_eof = false };
                }

                const n = self.readInternal(buf);

                if (!self.close_write) {
                    self.not_full.signal();
                }

                return .{ .n = n, .is_eof = false };
            }

            fn closeWriteRing(self: *RingBuf) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.close_err) return;
                if (!self.close_write) {
                    self.close_write = true;
                    self.not_full.broadcast();
                }
            }

            fn closeWithErrorRing(self: *RingBuf) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.close_err = true;
                if (!self.close_write) {
                    self.close_write = true;
                    self.not_full.broadcast();
                }
            }

            // -- Internal ring operations (called with mutex held) --
            // Matches Go's trackRingBuf: head/tail are virtual positions.
            // tail >= head always. tail - head = data length.
            // Actual buffer position = index % capacity.

            fn writeInternal(self: *RingBuf, p: []const u8) usize {
                const cap = self.buf.len;
                if (self.tail - self.head == cap) return 0;

                var n: usize = 0;

                // If tail hasn't wrapped yet (tail < cap), write to [tail..cap]
                if (self.tail < cap) {
                    const space = cap - self.tail;
                    const to_write = @min(p.len, space);
                    @memcpy(self.buf[self.tail..][0..to_write], p[0..to_write]);
                    n = to_write;
                    self.tail += to_write;
                }

                // If tail has wrapped (tail >= cap), write to [tail-cap..head]
                if (self.tail >= cap and n < p.len) {
                    const write_pos = self.tail - cap;
                    const space = self.head - write_pos;
                    const to_write = @min(p.len - n, space);
                    @memcpy(self.buf[write_pos..][0..to_write], p[n..][0..to_write]);
                    n += to_write;
                    self.tail += to_write;
                }

                return n;
            }

            fn readInternal(self: *RingBuf, p: []u8) usize {
                const cap = self.buf.len;
                var n: usize = 0;

                // If tail has wrapped (tail >= cap), read from [head..cap]
                if (self.tail >= cap) {
                    const available = cap - self.head;
                    const to_read = @min(p.len, available);
                    @memcpy(p[0..to_read], self.buf[self.head..][0..to_read]);
                    n = to_read;
                    self.head += to_read;
                    if (self.head == cap) {
                        self.head = 0;
                        self.tail -= cap;
                    }
                }

                // Read from [head..tail] (tail < cap here)
                if (self.tail < cap and n < p.len) {
                    const available = self.tail - self.head;
                    const to_read = @min(p.len - n, available);
                    @memcpy(p[n..][0..to_read], self.buf[self.head..][0..to_read]);
                    n += to_read;
                    self.head += to_read;
                }

                return n;
            }
        };

        // ================================================================
        // Platform sleep (for fade-out)
        // ================================================================

        fn sleepMs(ms: u32) void {
            if (@hasDecl(Rt, "sleepMs")) {
                Rt.sleepMs(ms);
            } else if (@hasDecl(Rt, "Time") and @hasDecl(Rt.Time, "sleepMs")) {
                Rt.Time.sleepMs(ms);
            }
            // If no sleep available, spin (degraded behavior)
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const std_import = @import("std");
const testing = std_import.testing;
const TestRt = @import("std_impl").runtime;

fn generateSineWave(comptime sample_rate: u32, freq: f64, duration_ms: u32) []i16 {
    const samples = sample_rate * duration_ms / 1000;
    const buf = testing.allocator.alloc(i16, samples) catch @panic("alloc failed");
    for (0..samples) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sample_rate));
        buf[i] = @intFromFloat(std_import.math.sin(2.0 * std_import.math.pi * freq * t) * 16000.0);
    }
    return buf;
}

fn readAll(mx: anytype, allocator: Allocator) ![]i16 {
    var result: std_import.ArrayList(i16) = .empty;
    defer result.deinit(allocator);
    var buf: [960]i16 = undefined;
    while (mx.read(&buf)) |n| {
        try result.appendSlice(allocator, buf[0..n]);
    }
    return try result.toOwnedSlice(allocator);
}

test "mixer creates track" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{ .output = .{ .rate = 16000 } });
    defer mx.deinit();

    const h = try mx.createTrack(.{ .label = "test" });

    try testing.expectEqualStrings("test", h.ctrl.getLabel());
    try testing.expect(h.ctrl.getGain() == 1.0);
    h.ctrl.closeWrite();
    mx.closeWrite();
}

test "mixer single track basic" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    // Just close immediately — read should return null
    mx.closeWrite();
    var buf: [160]i16 = undefined;
    try testing.expectEqual(@as(?usize, null), mx.read(&buf));
}

test "mixer single track with data" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});


    const data = [_]i16{1000} ** 160;
    try h.track.write(format, &data);
    h.ctrl.closeWrite();
    mx.closeWrite();

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);

    try testing.expect(mixed.len > 0);
}

test "mixer mixes two tracks" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };

    const h1 = try mx.createTrack(.{ .label = "440Hz" });

    const h2 = try mx.createTrack(.{ .label = "880Hz" });


    const wave1 = generateSineWave(16000, 440, 100);
    defer testing.allocator.free(wave1);
    const wave2 = generateSineWave(16000, 880, 100);
    defer testing.allocator.free(wave2);

    // Writer threads
    const t1 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, data: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h1.track, format, wave1, h1.ctrl });

    const t2 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, data: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h2.track, format, wave2, h2.ctrl });

    // Read mixed output
    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);

    t1.join();
    t2.join();

    try testing.expect(mixed.len > 0);

    // Analyze: count zero crossings
    var zero_crossings: usize = 0;
    var non_zero: usize = 0;
    var prev_sign = mixed[0] >= 0;
    for (mixed, 0..) |s, i| {
        if (s != 0) non_zero += 1;
        const sign = s >= 0;
        if (i > 0 and sign != prev_sign) zero_crossings += 1;
        prev_sign = sign;
    }

    // Two mixed sine waves should produce more zero crossings than a single 440Hz
    try testing.expect(zero_crossings > 100);
    try testing.expect(non_zero > mixed.len / 2);
}

test "mixer track gain" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{ .gain = 0.5 });


    try testing.expect(h.ctrl.getGain() == 0.5);

    // Write constant value
    const data = [_]i16{10000} ** 100;

    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, format, @as([]const i16, &data), h.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    // With 0.5 gain, 10000 should become ~5000
    for (mixed) |s| {
        if (s != 0) {
            const abs_s = if (s < 0) -s else s;
            try testing.expect(abs_s < 6000);
        }
    }
}

test "mixer auto close" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});


    const data = [_]i16{1000} ** 160;

    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, format, @as([]const i16, &data), h.ctrl });

    // read should eventually return null (EOF) due to auto-close
    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    try testing.expect(mixed.len > 0);
}

test "mixer concurrent write" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };

    const h1 = try mx.createTrack(.{ .label = "A" });

    const h2 = try mx.createTrack(.{ .label = "B" });


    const data_a = [_]i16{1000} ** 1600;
    const data_b = [_]i16{2000} ** 1600;

    const t1 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h1.track, format, @as([]const i16, &data_a), h1.ctrl });

    const t2 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h2.track, format, @as([]const i16, &data_b), h2.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);

    t1.join();
    t2.join();

    // Analyze: should have some samples near 1000, 2000, or 3000 (mixed)
    var count_a: usize = 0;
    var count_b: usize = 0;
    var count_mixed: usize = 0;
    for (mixed) |s| {
        const abs_diff_a = if (s > 1000) s - 1000 else 1000 - s;
        const abs_diff_b = if (s > 2000) s - 2000 else 2000 - s;
        const abs_diff_m = if (s > 3000) s - 3000 else 3000 - s;
        if (abs_diff_a < 100) count_a += 1;
        if (abs_diff_b < 100) count_b += 1;
        if (abs_diff_m < 100) count_mixed += 1;
    }

    try testing.expect(count_a + count_b + count_mixed > 0);
}

test "mixer close write" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    mx.closeWrite();

    // read should return null immediately
    var buf: [160]i16 = undefined;
    const result = mx.read(&buf);
    try testing.expectEqual(@as(?usize, null), result);
}

test "mixer create track after close returns error" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    mx.closeWrite();

    const result = mx.createTrack(.{});
    try testing.expectError(error.Closed, result);
}

test "mixer silence gap" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .silence_gap_ms = 100,
    });
    defer mx.deinit();

    // With silence_gap, read should return silence then eventually block
    // until a track is created. For this test, create a track and close it.
    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});


    const data = [_]i16{1000} ** 160;
    h.track.write(format, &data) catch {};
    h.ctrl.closeWrite();
    mx.closeWrite();

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    try testing.expect(mixed.len > 0);
}

test "mixer track label" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    const h = try mx.createTrack(.{ .label = "my-track" });

    try testing.expectEqualStrings("my-track", h.ctrl.getLabel());

    h.ctrl.closeWrite();
    mx.closeWrite();
}

test "mixer track read bytes" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});


    const data = [_]i16{1000} ** 160;

    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, format, @as([]const i16, &data), h.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    try testing.expect(h.ctrl.readBytes() > 0);
}

test "mixer callbacks" {
    const Mx = Mixer(TestRt);

    const State = struct {
        var created: u32 = 0;
        var closed: u32 = 0;

        fn onCreated() void {
            @atomicStore(u32, &created, @atomicLoad(u32, &created, .acquire) + 1, .release);
        }
        fn onClosed() void {
            @atomicStore(u32, &closed, @atomicLoad(u32, &closed, .acquire) + 1, .release);
        }
    };
    State.created = 0;
    State.closed = 0;

    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
        .on_track_created = &State.onCreated,
        .on_track_closed = &State.onClosed,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});

    try testing.expect(@atomicLoad(u32, &State.created, .acquire) == 1);

    const data = [_]i16{500} ** 160;
    h.track.write(format, &data) catch {};
    h.ctrl.closeWrite();

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);

    // Track should have been removed during read, triggering onClosed
    try testing.expect(@atomicLoad(u32, &State.closed, .acquire) >= 1);
}

test "mixer different sample rates" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    // Track 1: 16kHz (native)
    const h1 = try mx.createTrack(.{ .label = "16k" });

    // Track 2: 48kHz (needs resample to 16kHz)
    const h2 = try mx.createTrack(.{ .label = "48k" });


    const wave1 = generateSineWave(16000, 440, 100);
    defer testing.allocator.free(wave1);
    const wave2 = generateSineWave(48000, 880, 100);
    defer testing.allocator.free(wave2);

    const fmt16k = Mx.Format{ .rate = 16000 };
    const fmt48k = Mx.Format{ .rate = 48000 };

    const t1 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, data: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h1.track, fmt16k, wave1, h1.ctrl });

    const t2 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, data: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h2.track, fmt48k, wave2, h2.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);

    t1.join();
    t2.join();

    // Should have some audio output
    try testing.expect(mixed.len > 0);
    var non_zero: usize = 0;
    for (mixed) |s| {
        if (s != 0) non_zero += 1;
    }
    try testing.expect(non_zero > 0);
}
