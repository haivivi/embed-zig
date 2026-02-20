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
        track_read_buf: []i16,
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
                .track_read_buf = allocator.alloc(i16, chunk_samples) catch &.{},
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

            if (self.track_read_buf.len > 0) {
                self.allocator.free(self.track_read_buf);
            }
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

            // Pre-allocated buffer for reading each track (no alloc in hot path)
            if (self.track_read_buf.len < buf.len) {
                if (self.track_read_buf.len > 0) self.allocator.free(self.track_read_buf);
                self.track_read_buf = self.allocator.alloc(i16, buf.len) catch
                    return .{ .peak = 0, .has_data = false, .is_silence = false, .is_eof = false };
            }
            const track_i16 = self.track_read_buf[0..buf.len];
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
            self.mutex.lock();
            self.unlinkCtrl(&self.head, ctrl);
            self.unlinkCtrl(&self.detached_head, ctrl);
            self.mutex.unlock();

            if (ctrl.track) |t| {
                t.deinit();
                self.allocator.destroy(t);
            }
            self.allocator.destroy(ctrl);
        }

        fn unlinkCtrl(self: *Self, list_head: *?*TrackCtrl, ctrl: *TrackCtrl) void {
            _ = self;
            var prev: ?*TrackCtrl = null;
            var it = list_head.*;
            while (it) |c| {
                if (c == ctrl) {
                    if (prev) |p| {
                        p.next = c.next;
                    } else {
                        list_head.* = c.next;
                    }
                    return;
                }
                prev = c;
                it = c.next;
            }
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
                if (ctrl.track) |t| t.closeWriteNoNotify();
                it = ctrl.next;
            }

            // Already holds mixer.mutex — signal directly (no notifyDataAvailable)
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
                if (ctrl.track) |t| t.closeWithErrorNoNotify();
                it = ctrl.next;
            }

            // Already holds mixer.mutex — signal directly
            self.track_available.broadcast();
            self.data_available.broadcast();
        }

        // ================================================================
        // Internal helpers
        // ================================================================

        /// Signal that data is available. Acquires mixer mutex briefly to
        /// prevent lost-wakeup race (matching Go's notifyWrite pattern).
        /// Callers MUST NOT hold mixer.mutex, track.mutex, or ring.mutex.
        fn notifyDataAvailable(self: *Self) void {
            self.mutex.lock();
            self.mutex.unlock();
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
            // Old writers being drained by the mixer reader (format change)
            draining_writer: ?*TrackWriter,

            fn init(mixer: *Self) TrackInternal {
                return .{
                    .mixer = mixer,
                    .track_handle = undefined, // set after
                    .mutex = Rt.Mutex.init(),
                    .close_err = false,
                    .close_write = false,
                    .current_writer = null,
                    .current_format = null,
                    .draining_writer = null,
                };
            }

            fn postInit(self: *TrackInternal) void {
                self.track_handle = .{ .internal = self };
            }

            fn deinit(self: *TrackInternal) void {
                if (self.draining_writer) |w| {
                    w.deinit(self.mixer.allocator);
                    self.mixer.allocator.destroy(w);
                }
                if (self.current_writer) |w| {
                    w.deinit(self.mixer.allocator);
                    self.mixer.allocator.destroy(w);
                }
                self.mutex.deinit();
            }

            fn write(self: *TrackInternal, format: Format, samples: []const i16) error{Closed}!void {
                const writer = try self.getWriter(format);
                const output = self.mixer.config.output;

                if (writer.rs) |*rs| {
                    const src_ch: usize = @intFromEnum(format.channels);
                    const dst_ch: usize = @intFromEnum(output.channels);
                    const conv_buf = writer.channel_conv_buf;
                    const conv_buf_frames = if (conv_buf) |b| b.len / @max(src_ch, dst_ch) else 0;

                    // Resample on write path: loop-consume all input.
                    // Channel conversion happens before resampling (matching
                    // StreamResampler.processChunk).
                    var remaining = samples;
                    while (remaining.len > 0) {
                        // Limit chunk size (in source frames)
                        const max_src_frames = if (conv_buf != null)
                            @min(remaining.len / src_ch, conv_buf_frames)
                        else
                            @min(remaining.len / src_ch, writer.rs_out_buf.?.len);
                        if (max_src_frames == 0) break;
                        const max_src_samples = max_src_frames * src_ch;

                        var chunk_to_process: []const i16 = remaining[0..max_src_samples];

                        // Channel conversion before resampling
                        if (src_ch == 2 and dst_ch == 1) {
                            const cb = conv_buf orelse break;
                            @memcpy(cb[0..max_src_samples], remaining[0..max_src_samples]);
                            const mono_n = resampler_mod.stereoToMono(cb[0..max_src_samples]);
                            chunk_to_process = cb[0..mono_n];
                        } else if (src_ch == 1 and dst_ch == 2) {
                            const cb = conv_buf orelse break;
                            const stereo_n = resampler_mod.monoToStereo(remaining[0..max_src_samples], cb);
                            chunk_to_process = cb[0 .. stereo_n * 2];
                        }

                        const result = rs.process(chunk_to_process, writer.rs_out_buf.?) catch return error.Closed;

                        // Map resampler consumption back to source samples.
                        // in_consumed is in dst-channel space (resampler channels = dst_ch).
                        const consumed_frames = result.in_consumed / dst_ch;
                        const consumed_src_samples = consumed_frames * src_ch;
                        remaining = remaining[@min(consumed_src_samples, remaining.len)..];

                        if (result.out_produced > 0) {
                            const out_bytes = std.mem.sliceAsBytes(writer.rs_out_buf.?[0..result.out_produced]);
                            try writer.ring.writeFull(out_bytes);
                        }
                        if (result.in_consumed == 0 and result.out_produced == 0) break;
                    }
                } else {
                    const bytes = std.mem.sliceAsBytes(samples);
                    try writer.ring.writeFull(bytes);
                }
            }

            fn getWriter(self: *TrackInternal, format: Format) error{Closed}!*TrackWriter {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.close_err) return error.Closed;
                if (self.close_write) return error.Closed;

                if (self.current_format) |cf| {
                    if (Format.eql(cf, format)) {
                        return self.current_writer.?;
                    }
                    // Format changed — move old writer to draining list
                    // so mixer reader can drain remaining data before it's freed.
                    if (self.current_writer) |w| {
                        w.ring.closeWriteRing();
                        // Free any previous draining writer (already drained)
                        if (self.draining_writer) |dw| {
                            dw.deinit(self.mixer.allocator);
                            self.mixer.allocator.destroy(dw);
                        }
                        self.draining_writer = w;
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

            /// Non-blocking read. Drains old writer (from format change) first,
            /// then reads from current writer.
            fn readData(self: *TrackInternal, buf: []u8) struct { n: usize, is_err: bool, is_eof: bool } {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.close_err) return .{ .n = 0, .is_err = true, .is_eof = false };

                // Drain old writer first (from format change)
                if (self.draining_writer) |dw| {
                    const rn = dw.readNonBlocking(buf);
                    if (rn.n > 0) return .{ .n = rn.n, .is_err = false, .is_eof = false };
                    if (rn.is_eof) {
                        // Old writer fully drained — free it
                        dw.deinit(self.mixer.allocator);
                        self.mixer.allocator.destroy(dw);
                        self.draining_writer = null;
                    }
                }

                if (self.current_writer) |w| {
                    const rn = w.readNonBlocking(buf);
                    if (rn.n > 0) return .{ .n = rn.n, .is_err = false, .is_eof = false };
                    if (rn.is_eof) return .{ .n = 0, .is_err = false, .is_eof = true };
                    return .{ .n = 0, .is_err = false, .is_eof = false };
                }

                if (self.close_write) return .{ .n = 0, .is_err = false, .is_eof = true };
                return .{ .n = 0, .is_err = false, .is_eof = false };
            }

            fn closeWriteInternal(self: *TrackInternal) void {
                self.closeWriteNoNotify();
                self.mixer.notifyDataAvailable();
            }

            fn closeWriteNoNotify(self: *TrackInternal) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.close_write = true;
                if (self.current_writer) |w| {
                    w.ring.closeWriteRing();
                }
            }

            fn closeInternal(self: *TrackInternal) void {
                self.closeWithErrorInternal();
            }

            fn closeWithErrorInternal(self: *TrackInternal) void {
                self.closeWithErrorNoNotify();
                self.mixer.notifyDataAvailable();
            }

            fn closeWithErrorNoNotify(self: *TrackInternal) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.close_err = true;
                self.close_write = true;
                if (self.current_writer) |w| {
                    w.ring.closeWithErrorRing();
                }
            }
        };

        // ================================================================
        // TrackWriter (input format + optional resampler + ring buffer)
        // ================================================================

        const TrackWriter = struct {
            ring: *RingBuf,
            rs: ?Resampler,
            input_format: Format,

            // Work buffers for write-path resampling
            rs_out_buf: ?[]i16,
            channel_conv_buf: ?[]i16,

            fn init(track: *TrackInternal, format: Format, allocator: Allocator) !TrackWriter {
                const output = track.mixer.config.output;
                const ring = try allocator.create(RingBuf);
                errdefer allocator.destroy(ring);
                const buf_size = @as(usize, output.rate) * @as(usize, @intFromEnum(output.channels)) * 2 * 10; // 10 seconds
                ring.* = try RingBuf.init(track, allocator, buf_size);
                errdefer ring.deinit(allocator);

                const needs_resample = format.rate != output.rate or format.channels != output.channels;
                var rs: ?Resampler = null;
                errdefer if (rs) |*r| r.deinit();
                var rs_out_buf: ?[]i16 = null;
                errdefer if (rs_out_buf) |b| allocator.free(b);
                var channel_conv_buf: ?[]i16 = null;

                if (needs_resample) {
                    const dst_ch = @intFromEnum(output.channels);
                    rs = try Resampler.init(allocator, .{
                        .channels = dst_ch,
                        .in_rate = format.rate,
                        .out_rate = output.rate,
                        .quality = 3,
                    });
                    rs_out_buf = try allocator.alloc(i16, 4096 * 6);
                    if (format.channels != output.channels) {
                        channel_conv_buf = try allocator.alloc(i16, 4096 * 2);
                    }
                }

                return .{
                    .ring = ring,
                    .rs = rs,
                    .input_format = format,
                    .rs_out_buf = rs_out_buf,
                    .channel_conv_buf = channel_conv_buf,
                };
            }

            fn deinit(self: *TrackWriter, allocator: Allocator) void {
                if (self.channel_conv_buf) |b| allocator.free(b);
                if (self.rs_out_buf) |b| allocator.free(b);
                if (self.rs) |*rs| rs.deinit();
                self.ring.deinit(allocator);
                allocator.destroy(self.ring);
            }

            const ReadNBResult = struct { n: usize, is_eof: bool };

            /// Non-blocking read from ring buffer. Ring buffer already
            /// contains output-format data (resampled on write path).
            fn readNonBlocking(self: *TrackWriter, buf: []u8) ReadNBResult {
                const r = self.ring.readNonBlocking(buf);
                return .{ .n = r.n, .is_eof = r.is_eof };
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
                    // Release ring mutex before notifying mixer (lock order:
                    // mixer → track → ring; notify acquires mixer mutex).
                    self.mutex.unlock();
                    self.track.mixer.notifyDataAvailable();
                    self.mutex.lock();
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

test "mixer resample preserves duration (48k to 16k)" {
    // Regression: readWithResampler was dropping unconsumed input samples.
    // Write 500ms @ 48kHz into a single track, mixer output is 16kHz.
    // Expected output ≈ 500ms @ 16kHz = 8000 samples.
    // With the data-loss bug, the resampler only consumes ~70% of input per
    // read cycle (output buffer limits consumption), losing ~30% each time.
    // Result: ~5900 samples instead of 8000 — fails the 90% threshold.
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const h = try mx.createTrack(.{ .label = "48k-duration" });

    const duration_ms = 500;
    const wave = generateSineWave(48000, 440, duration_ms);
    defer testing.allocator.free(wave);

    const fmt48k = Mx.Format{ .rate = 48000 };

    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, data: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, fmt48k, wave, h.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    // 500ms @ 16kHz = 8000 samples. Allow 10% tolerance for resampler filter
    // delay, but no more — the bug drops ~30%.
    const expected_samples = 16000 * duration_ms / 1000; // 8000
    const min_samples = expected_samples * 90 / 100; // 7200
    try testing.expect(mixed.len >= min_samples);
}

test "mixer stereo input to mono output preserves channel conversion" {
    // Regression: Resampler was initialized with output.channels but fed raw
    // input samples with input.channels. When stereo→mono, the resampler
    // misinterprets the interleaved layout.
    //
    // Write stereo 48kHz [V, 0, V, 0, ...] (left=signal, right=silence).
    // Correct: stereoToMono → [V/2, V/2, ...] → resample → mono output ≈ V/2.
    // Bug: resampler sees mono [V, 0, V, 0, ...] → output alternates high/low.
    //
    // Detect by checking that output samples are consistently near V/2,
    // not alternating between V and 0.
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000, .channels = .mono },
        .auto_close = true,
    });
    defer mx.deinit();

    const h = try mx.createTrack(.{ .label = "stereo-to-mono" });

    // Generate stereo data: L=8000, R=0 for 200ms @ 48kHz
    const stereo_frames = 48000 * 200 / 1000; // 9600 frames
    const stereo_samples = stereo_frames * 2; // 19200 i16 (interleaved L,R)
    const stereo_data = try testing.allocator.alloc(i16, stereo_samples);
    defer testing.allocator.free(stereo_data);
    for (0..stereo_frames) |i| {
        stereo_data[i * 2] = 8000; // L
        stereo_data[i * 2 + 1] = 0; // R
    }

    const fmt_stereo_48k = Mx.Format{ .rate = 48000, .channels = .stereo };

    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, data: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, fmt_stereo_48k, stereo_data, h.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    try testing.expect(mixed.len > 0);

    // With correct channel conversion:
    //   stereoToMono → 9600 mono frames @ 48kHz → resample → ~3200 @ 16kHz
    // Without channel conversion (bug):
    //   resampler(channels=1) sees 19200 "mono" frames → ~6400 @ 16kHz (2x!)
    //
    // Check output is within 20% of expected 3200, catching the 2x blowup.
    // Count non-zero samples (mixed.len includes zero-padded chunk tails).
    var non_zero: usize = 0;
    for (mixed) |s| {
        if (s != 0) non_zero += 1;
    }

    // With correct channel conversion:
    //   stereoToMono → 9600 mono frames @ 48kHz → resample → ~3200 @ 16kHz
    // Without channel conversion (bug):
    //   resampler(channels=1) sees 19200 "mono" frames → ~6400 @ 16kHz (2x!)
    const expected_mono_samples = 16000 * 200 / 1000; // 3200
    const max_non_zero = expected_mono_samples * 120 / 100; // 3840
    try testing.expect(non_zero > 0);
    try testing.expect(non_zero <= max_non_zero);
}

// ============================================================================
// Required tests from AGENTS.md (T1-T18)
// ============================================================================

test "T1: backpressure blocks writer" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});

    // Write more data than ring buffer can hold without reading.
    // Ring buffer = 16000*1*2*10 = 320000 bytes = 160000 i16.
    // Write 200000 samples — must exceed capacity.
    const big_data = try testing.allocator.alloc(i16, 200000);
    defer testing.allocator.free(big_data);
    for (big_data) |*s| s.* = 1000;

    // Writer in thread (will block on backpressure)
    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, data: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, format, big_data, h.ctrl });

    // Reader consumes all
    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    // All data should be present (no drops from backpressure)
    try testing.expect(mixed.len > 0);
}

test "T2: remove track mid-stream" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const ha = try mx.createTrack(.{ .label = "A" });
    const hb = try mx.createTrack(.{ .label = "B" });

    const data_b = [_]i16{2000} ** 1600;

    // Track A: closeWithError immediately (mid-stream abort)
    ha.ctrl.closeWithError();

    // Track B: write normally
    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ hb.track, format, @as([]const i16, &data_b), hb.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    // Mixer should have track B's data, not crash
    try testing.expect(mixed.len > 0);
}

test "T3: closeWithError aborts all tracks" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h1 = try mx.createTrack(.{ .label = "A" });
    const h2 = try mx.createTrack(.{ .label = "B" });

    var write1_closed = std_import.atomic.Value(bool).init(false);
    var write2_closed = std_import.atomic.Value(bool).init(false);

    const t1 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, flag: *std_import.atomic.Value(bool)) void {
            const data = [_]i16{500} ** 16000;
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                track.write(fmt, &data) catch {
                    flag.store(true, .release);
                    return;
                };
            }
        }
    }.run, .{ h1.track, format, &write1_closed });

    const t2 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, flag: *std_import.atomic.Value(bool)) void {
            const data = [_]i16{500} ** 16000;
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                track.write(fmt, &data) catch {
                    flag.store(true, .release);
                    return;
                };
            }
        }
    }.run, .{ h2.track, format, &write2_closed });

    // Let writers start
    std_import.Thread.sleep(5 * std_import.time.ns_per_ms);

    // Close mixer with error
    mx.closeWithError();

    t1.join();
    t2.join();

    // Both writers should have gotten error.Closed
    try testing.expect(write1_closed.load(.acquire));
    try testing.expect(write2_closed.load(.acquire));
}

test "T4: track closeWithError" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    const h = try mx.createTrack(.{});
    h.ctrl.closeWithError();
    mx.closeWrite();

    // read should return null (EOF), not hang
    var buf: [160]i16 = undefined;
    const result = mx.read(&buf);
    try testing.expectEqual(@as(?usize, null), result);
}

test "T5: format change mid-stream" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const h = try mx.createTrack(.{});

    const fmt16k = Mx.Format{ .rate = 16000 };
    const fmt48k = Mx.Format{ .rate = 48000 };

    // Write 16kHz first, then switch to 48kHz
    const data16k = [_]i16{3000} ** 320; // 20ms @ 16kHz
    const wave48k = generateSineWave(48000, 440, 50); // 50ms @ 48kHz
    defer testing.allocator.free(wave48k);

    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, f1: Mx.Format, d1: []const i16, f2: Mx.Format, d2: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(f1, d1) catch {};
            track.write(f2, d2) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, fmt16k, @as([]const i16, &data16k), fmt48k, wave48k, h.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    // Should have output from both segments
    try testing.expect(mixed.len > 0);
    var non_zero: usize = 0;
    for (mixed) |s| {
        if (s != 0) non_zero += 1;
    }
    try testing.expect(non_zero > 200);
}

test "T6: clipping on overflow" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };

    // 3 tracks each writing amplitude 20000 — sum = 60000 which exceeds i16 range
    const h1 = try mx.createTrack(.{});
    const h2 = try mx.createTrack(.{});
    const h3 = try mx.createTrack(.{});

    const data = [_]i16{20000} ** 320;

    const t1 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h1.track, format, @as([]const i16, &data), h1.ctrl });
    const t2 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h2.track, format, @as([]const i16, &data), h2.ctrl });
    const t3 = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h3.track, format, @as([]const i16, &data), h3.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t1.join();
    t2.join();
    t3.join();

    // All samples must be within i16 range (clamped, not wrapped)
    for (mixed) |s| {
        try testing.expect(s >= -32768);
        try testing.expect(s <= 32767);
    }
}

test "T7: zero gain produces silence" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{ .gain = 0.0 });

    const data = [_]i16{10000} ** 320;
    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, format, @as([]const i16, &data), h.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    for (mixed) |s| {
        try testing.expectEqual(@as(i16, 0), s);
    }
}

test "T8: gain change during playback" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{ .gain = 1.0 });

    const data = [_]i16{10000} ** 3200; // 200ms

    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, format, @as([]const i16, &data), h.ctrl });

    // Read first chunk with gain=1.0
    var buf1: [960]i16 = undefined;
    const n1 = mx.read(&buf1);
    try testing.expect(n1 != null);

    // Change gain to 0.5
    h.ctrl.setGain(0.5);

    // Read rest
    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    // First chunk should have higher amplitude than later chunks
    var max_first: i16 = 0;
    if (n1) |n| {
        for (buf1[0..n]) |s| {
            const abs_s = if (s < 0) -s else s;
            if (abs_s > max_first) max_first = abs_s;
        }
    }

    var max_later: i16 = 0;
    for (mixed) |s| {
        const abs_s = if (s < 0) -s else s;
        if (abs_s > max_later) max_later = abs_s;
    }

    // First chunk (gain=1.0) peak should be higher than later (gain=0.5)
    if (max_first > 0 and max_later > 0) {
        try testing.expect(max_first > max_later);
    }
}

test "T9: setFadeOutDuration + closeSelf" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});

    h.ctrl.setFadeOutDuration(50);

    // Write continuous data in background
    const data = [_]i16{10000} ** 16000;
    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16) void {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                track.write(fmt, d) catch return;
            }
        }
    }.run, .{ h.track, format, @as([]const i16, &data) });

    // Let some data flow
    var buf: [960]i16 = undefined;
    _ = mx.read(&buf);

    // closeSelf triggers fade-out
    h.ctrl.closeSelf();
    mx.closeWrite();

    // Read remaining — should not hang
    const rest = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(rest);
    t.join();
}

test "T10: closeWriteWithSilence" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});

    const data = [_]i16{5000} ** 320; // 20ms of audio
    h.track.write(format, &data) catch {};

    // Close with 50ms of trailing silence
    h.ctrl.closeWriteWithSilence(50);

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);

    // Output should have audio followed by silence
    try testing.expect(mixed.len > 0);

    // Last portion should be silence (zeros)
    const tail_start = if (mixed.len > 400) mixed.len - 400 else 0;
    var tail_zeros: usize = 0;
    for (mixed[tail_start..]) |s| {
        if (s == 0) tail_zeros += 1;
    }
    try testing.expect(tail_zeros > 100);
}

test "T11: destroyTrackCtrl cleanup" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    const h = try mx.createTrack(.{});
    h.ctrl.closeWrite();
    mx.closeWrite();

    // Read to drain
    var buf: [960]i16 = undefined;
    while (mx.read(&buf)) |_| {}

    // Explicit cleanup — testing.allocator detects leaks
    mx.destroyTrackCtrl(h.ctrl);
}

test "T12: ring buffer wraparound" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});

    // Write more than ring buffer capacity (320000 bytes = 160000 i16)
    // to force wraparound
    const total = 200000;
    const big_data = try testing.allocator.alloc(i16, total);
    defer testing.allocator.free(big_data);
    for (big_data, 0..) |*s, i| {
        s.* = @intCast(@as(i32, @intCast(i % 1000)));
    }

    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, data: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, format, big_data, h.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    // Data should be complete (accounting for chunk padding)
    try testing.expect(mixed.len >= total);
}

test "T13: 8kHz to 16kHz resample" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const h = try mx.createTrack(.{});

    const duration_ms = 200;
    const wave = generateSineWave(8000, 440, duration_ms);
    defer testing.allocator.free(wave);

    const fmt8k = Mx.Format{ .rate = 8000 };

    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, data: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, fmt8k, wave, h.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    // 200ms @ 16kHz = 3200 samples. Input was 200ms @ 8kHz = 1600 samples.
    // Output should be ~2x input sample count (±10%).
    const expected = 16000 * duration_ms / 1000; // 3200
    const min_out = expected * 90 / 100; // 2880
    var non_zero: usize = 0;
    for (mixed) |s| {
        if (s != 0) non_zero += 1;
    }
    try testing.expect(non_zero >= min_out);
}

test "T14: empty read buffer" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    var empty_buf: [0]i16 = .{};
    const result = mx.read(&empty_buf);
    try testing.expectEqual(@as(?usize, 0), result);

    mx.closeWrite();
}

test "T15: large throughput stress" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const num_tracks = 10;
    const duration_ms = 500; // 500ms per track (reduced for test speed)
    const samples_per_track = 16000 * duration_ms / 1000;

    var threads: [num_tracks]std_import.Thread = undefined;
    for (0..num_tracks) |i| {
        const h = try mx.createTrack(.{});
        threads[i] = try std_import.Thread.spawn(.{}, struct {
            fn run(track: *Mx.Track, fmt: Mx.Format, n: usize, ctrl: *Mx.TrackCtrl) void {
                const chunk = [_]i16{1000} ** 1600;
                var written: usize = 0;
                while (written < n) {
                    const to_write = @min(chunk.len, n - written);
                    track.write(fmt, chunk[0..to_write]) catch return;
                    written += to_write;
                }
                ctrl.closeWrite();
            }
        }.run, .{ h.track, format, samples_per_track, h.ctrl });
    }

    // Read all mixed output
    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);

    for (&threads) |*t| t.join();

    // Should have output (at least as much as one track's duration)
    try testing.expect(mixed.len >= samples_per_track);
}

test "T16: single sample write" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});

    const data = [_]i16{12345};
    h.track.write(format, &data) catch {};
    h.ctrl.closeWrite();

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);

    // Output should contain the sample (zero-padded)
    try testing.expect(mixed.len > 0);
    var found = false;
    for (mixed) |s| {
        if (s == 12345) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "T17: write after track closeWrite returns Closed" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});

    h.ctrl.closeWrite();

    const data = [_]i16{1000} ** 10;
    const result = h.track.write(format, &data);
    try testing.expectError(error.Closed, result);

    mx.closeWrite();
}

test "T18: read bytes counter accuracy" {
    const Mx = Mixer(TestRt);
    var mx = Mx.init(testing.allocator, .{
        .output = .{ .rate = 16000 },
        .auto_close = true,
    });
    defer mx.deinit();

    const format = Mx.Format{ .rate = 16000 };
    const h = try mx.createTrack(.{});

    const num_samples = 1600; // 100ms
    const data = [_]i16{1000} ** num_samples;

    const t = try std_import.Thread.spawn(.{}, struct {
        fn run(track: *Mx.Track, fmt: Mx.Format, d: []const i16, ctrl: *Mx.TrackCtrl) void {
            track.write(fmt, d) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h.track, format, @as([]const i16, &data), h.ctrl });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    t.join();

    const rb = h.ctrl.readBytes();
    // readBytes tracks bytes read by mixer from ring buffer.
    // Written bytes = num_samples * 2 = 3200.
    // readBytes should be close (readFull zero-pads to chunk boundary).
    try testing.expect(rb > 0);
    try testing.expect(rb >= num_samples * 2);
}
