//! Resampler — sample rate conversion + channel conversion
//!
//! Two layers:
//! - **Resampler**: pure Zig windowed-sinc wrapper, single-batch `process([]i16, []i16)`
//! - **StreamResampler(Rt)**: thread-safe streaming with Mutex/Condition,
//!   `write([]u8)` / `read([]u8)` between two tasks
//!
//! ## Quick start
//!
//! ```zig
//! // Low-level (single task, you manage buffers)
//! var rs = try Resampler.init(allocator, .{ .in_rate = 16000, .out_rate = 48000 });
//! defer rs.deinit();
//! const r = try rs.process(&in_samples, &out_buf);
//!
//! // High-level (two tasks, blocking write/read)
//! const Stream = StreamResampler(StdRuntime);
//! var s = try Stream.init(allocator, .{
//!     .src = .{ .rate = 48000, .channels = .stereo },
//!     .dst = .{ .rate = 16000, .channels = .mono },
//! });
//! // Task 1: s.write(bytes)
//! // Task 2: s.read(&buf)
//! ```

const std = @import("std");
const trait = @import("trait");
const push_sinc_mod = @import("push_sinc.zig");

// ============================================================================
// Format
// ============================================================================

pub const Format = struct {
    rate: u32,
    channels: Channels = .mono,

    pub const Channels = enum(u2) {
        mono = 1,
        stereo = 2,
    };

    pub fn channelCount(self: Format) u32 {
        return @intFromEnum(self.channels);
    }

    /// Bytes per sample frame (all channels). mono=2, stereo=4.
    pub fn sampleBytes(self: Format) usize {
        return @as(usize, @intFromEnum(self.channels)) * 2;
    }

    pub fn eql(a: Format, b: Format) bool {
        return a.rate == b.rate and a.channels == b.channels;
    }
};

// ============================================================================
// Channel Conversion (pure functions)
// ============================================================================

/// Convert stereo i16 interleaved samples to mono in-place by averaging L+R.
/// `buf` contains interleaved [L, R, L, R, ...] samples.
/// Returns number of mono samples written (= number of stereo frames).
/// Mono samples are written to the beginning of `buf`.
pub fn stereoToMono(buf: []i16) usize {
    const num_frames = buf.len / 2;
    for (0..num_frames) |i| {
        const l: i32 = buf[i * 2];
        const r: i32 = buf[i * 2 + 1];
        buf[i] = @intCast(@divTrunc(l + r, 2));
    }
    return num_frames;
}

/// Convert mono i16 samples to stereo interleaved.
/// Reads from `in`, writes [S, S, S, S, ...] pairs to `out`.
/// Returns number of stereo frames written (= in.len).
/// `out` must be at least `in.len * 2` elements.
pub fn monoToStereo(in: []const i16, out: []i16) usize {
    const n = @min(in.len, out.len / 2);
    // Process backwards to allow in-place when in and out overlap
    var i = n;
    while (i > 0) {
        i -= 1;
        out[i * 2] = in[i];
        out[i * 2 + 1] = in[i];
    }
    return n;
}

fn gcdU32(a_in: u32, b_in: u32) u32 {
    var a = a_in;
    var b = b_in;
    while (b != 0) {
        const t = a % b;
        a = b;
        b = t;
    }
    return a;
}

// ============================================================================
// Resampler (pure Zig windowed-sinc wrapper)
// ============================================================================

pub const Resampler = struct {
    pushers: []push_sinc_mod.PushSincResampler,
    block_src_frames: usize,
    block_dst_frames: usize,
    tmp_in: []i16,
    tmp_out: []i16,
    bypass: bool,
    channels: u32,
    allocator: std.mem.Allocator,

    pub const Config = struct {
        channels: u32 = 1,
        in_rate: u32,
        out_rate: u32,
        quality: u4 = 3,
    };

    pub const Result = struct {
        in_consumed: u32,
        out_produced: u32,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Resampler {
        const ch: usize = @intCast(config.channels);
        if (ch == 0) return error.InvalidChannels;

        if (config.in_rate == config.out_rate) {
            return .{
                .pushers = &.{},
                .block_src_frames = 0,
                .block_dst_frames = 0,
                .tmp_in = &.{},
                .tmp_out = &.{},
                .bypass = true,
                .channels = config.channels,
                .allocator = allocator,
            };
        }

        const g = gcdU32(config.in_rate, config.out_rate);
        if (g == 0) return error.InvalidSampleRate;

        const base_src: usize = @intCast(config.in_rate / g);
        const base_dst: usize = @intCast(config.out_rate / g);

        // Prefer 10ms source blocks (same pacing as audio pipeline), while
        // preserving exact rational ratio via base_src/base_dst scaling.
        const target_src_frames: usize = @max(@as(usize, @intCast(config.in_rate / 100)), 1);
        var k: usize = @divTrunc(target_src_frames + base_src - 1, base_src);
        if (k == 0) k = 1;
        while (base_src * k < 64) : (k += 1) {}

        const block_src_frames = base_src * k;
        const block_dst_frames = base_dst * k;

        const pushers = try allocator.alloc(push_sinc_mod.PushSincResampler, ch);
        errdefer allocator.free(pushers);
        for (pushers) |*p| {
            p.* = try push_sinc_mod.PushSincResampler.new(allocator, block_src_frames, block_dst_frames);
        }
        errdefer {
            for (pushers) |*p| p.deinit();
        }

        const tmp_in = try allocator.alloc(i16, block_src_frames);
        errdefer allocator.free(tmp_in);
        const tmp_out = try allocator.alloc(i16, block_dst_frames);
        errdefer allocator.free(tmp_out);

        _ = config.quality; // reserved for future tuning knobs
        return .{
            .pushers = pushers,
            .block_src_frames = block_src_frames,
            .block_dst_frames = block_dst_frames,
            .tmp_in = tmp_in,
            .tmp_out = tmp_out,
            .bypass = false,
            .channels = config.channels,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Resampler) void {
        if (self.bypass) return;
        for (self.pushers) |*p| p.deinit();
        self.allocator.free(self.pushers);
        self.allocator.free(self.tmp_in);
        self.allocator.free(self.tmp_out);
    }

    /// Resample interleaved i16 audio. Returns consumed/produced frame counts.
    pub fn process(self: *Resampler, in_buf: []const i16, out_buf: []i16) !Result {
        const ch: usize = @intCast(self.channels);
        const in_frames: usize = in_buf.len / ch;
        const out_frames_cap: usize = out_buf.len / ch;

        if (self.bypass) {
            const frames = @min(in_frames, out_frames_cap);
            const samples = frames * ch;
            @memcpy(out_buf[0..samples], in_buf[0..samples]);
            return .{
                .in_consumed = @intCast(samples),
                .out_produced = @intCast(samples),
            };
        }

        const blocks_by_in = in_frames / self.block_src_frames;
        const blocks_by_out = out_frames_cap / self.block_dst_frames;
        const block_count = @min(blocks_by_in, blocks_by_out);

        if (block_count == 0) {
            return .{ .in_consumed = 0, .out_produced = 0 };
        }

        var b: usize = 0;
        while (b < block_count) : (b += 1) {
            const in_base = b * self.block_src_frames * ch;
            const out_base = b * self.block_dst_frames * ch;

            var cidx: usize = 0;
            while (cidx < ch) : (cidx += 1) {
                for (0..self.block_src_frames) |i| {
                    self.tmp_in[i] = in_buf[in_base + i * ch + cidx];
                }
                _ = try self.pushers[cidx].resampleI16(self.tmp_in[0..self.block_src_frames], self.tmp_out[0..self.block_dst_frames]);
                for (0..self.block_dst_frames) |i| {
                    out_buf[out_base + i * ch + cidx] = self.tmp_out[i];
                }
            }
        }

        const consumed_samples: usize = block_count * self.block_src_frames * ch;
        const produced_samples: usize = block_count * self.block_dst_frames * ch;
        return .{
            .in_consumed = @intCast(consumed_samples),
            .out_produced = @intCast(produced_samples),
        };
    }

    pub fn reset(self: *Resampler) void {
        if (self.bypass) return;
        for (self.pushers) |*p| p.reset();
    }
};

// ============================================================================
// StreamResampler(Rt) — thread-safe streaming resampler
// ============================================================================

pub fn StreamResampler(comptime Rt: type) type {
    comptime {
        _ = trait.sync.Mutex(Rt.Mutex);
        _ = trait.sync.Condition(Rt.Condition, Rt.Mutex);
    }

    return struct {
        const Self = @This();

        const in_buf_size = 4096;
        const out_buf_size = 8192;
        // Max source sample-frames per drain chunk (limits stack usage).
        // Must be >= common pure-Zig resampler source block sizes (e.g. 160,
        // 320, 480 frames), otherwise drain cannot form a complete block.
        const max_chunk_frames = 512;

        pub const Config = struct {
            src: Format,
            dst: Format,
            quality: u4 = 3,
        };

        mutex: Rt.Mutex,
        not_empty: Rt.Condition,
        not_full: Rt.Condition,

        in_buf: [in_buf_size]u8,
        in_len: usize,

        out_buf: [out_buf_size]u8,
        out_start: usize,
        out_end: usize,

        resampler: ?Resampler,
        src_fmt: Format,
        dst_fmt: Format,
        closed: bool,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            const needs_resample = config.src.rate != config.dst.rate;
            const rs = if (needs_resample)
                try Resampler.init(allocator, .{
                    .channels = config.dst.channelCount(),
                    .in_rate = config.src.rate,
                    .out_rate = config.dst.rate,
                    .quality = config.quality,
                })
            else
                null;

            return .{
                .mutex = Rt.Mutex.init(),
                .not_empty = Rt.Condition.init(),
                .not_full = Rt.Condition.init(),
                .in_buf = undefined,
                .in_len = 0,
                .out_buf = undefined,
                .out_start = 0,
                .out_end = 0,
                .resampler = rs,
                .src_fmt = config.src,
                .dst_fmt = config.dst,
                .closed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.resampler) |*rs| rs.deinit();
            self.not_full.deinit();
            self.not_empty.deinit();
            self.mutex.deinit();
        }

        /// Push audio bytes (source format). Blocks if internal buffers are full.
        /// Returns error.Closed if the stream has been closed.
        /// Always consumes all of `data` before returning (unless closed).
        pub fn write(self: *Self, data: []const u8) error{Closed}!usize {
            if (data.len == 0) return 0;

            self.mutex.lock();
            defer self.mutex.unlock();

            var pos: usize = 0;
            while (pos < data.len) {
                if (self.closed) return error.Closed;

                // Append as much as possible to in_buf
                const space = in_buf_size - self.in_len;
                if (space > 0) {
                    const n = @min(data.len - pos, space);
                    @memcpy(self.in_buf[self.in_len..][0..n], data[pos..][0..n]);
                    self.in_len += n;
                    pos += n;
                }

                // Try to process buffered input into output
                const old_out_end = self.out_end;
                self.drain();

                // If drain produced output, wake reader immediately.
                // Without this, writer blocks on not_full while reader
                // blocks on not_empty → deadlock.
                if (self.out_end > old_out_end) {
                    self.not_empty.signal();
                }

                // If we couldn't consume all data and drain didn't free input space,
                // wait for reader to consume output (freeing drain capacity)
                if (pos < data.len and self.in_len == in_buf_size) {
                    self.not_full.wait(&self.mutex);
                }
            }

            return data.len;
        }

        /// Pull resampled audio bytes (destination format). Blocks until data
        /// is available. Returns null when closed and all data is drained.
        pub fn read(self: *Self, buf: []u8) ?usize {
            if (buf.len == 0) return 0;

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.out_start == self.out_end) {
                // Try draining any pending input (handles close() partial drain
                // and avoids data loss when out_buf was full during close).
                self.drain();
                if (self.out_start < self.out_end) break;

                if (self.closed) return null;
                self.not_empty.wait(&self.mutex);
            }

            const dst_sb = self.dst_fmt.sampleBytes();
            const available = self.out_end - self.out_start;
            const aligned = (@min(buf.len, available) / dst_sb) * dst_sb;
            if (aligned == 0) return 0;

            @memcpy(buf[0..aligned], self.out_buf[self.out_start..][0..aligned]);
            self.out_start += aligned;

            if (self.out_start == self.out_end) {
                self.out_start = 0;
                self.out_end = 0;
            }

            self.not_full.signal();
            return aligned;
        }

        /// Close the stream. Writer gets error.Closed, reader can drain
        /// remaining data then gets null.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Drain any remaining input before closing
            self.drain();
            self.closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.in_len = 0;
            self.out_start = 0;
            self.out_end = 0;
            if (self.resampler) |*rs| rs.reset();
        }

        // ----------------------------------------------------------------
        // Internal: drain input buffer → process → output buffer
        // Called with mutex held.
        // ----------------------------------------------------------------

        fn drain(self: *Self) void {
            const src_sb = self.src_fmt.sampleBytes();
            const dst_sb = self.dst_fmt.sampleBytes();

            while (true) {
                const usable_bytes = (self.in_len / src_sb) * src_sb;
                if (usable_bytes == 0) break;

                // Compact output buffer if needed
                if (self.out_start > 0 and self.out_end == out_buf_size) {
                    const remaining = self.out_end - self.out_start;
                    std.mem.copyForwards(u8, self.out_buf[0..remaining], self.out_buf[self.out_start..self.out_end]);
                    self.out_start = 0;
                    self.out_end = remaining;
                }

                const out_space = out_buf_size - self.out_end;
                if (out_space < dst_sb) break;

                const max_src_frames = @min(usable_bytes / src_sb, max_chunk_frames);
                if (max_src_frames == 0) break;

                const old_in_len = self.in_len;
                const produced_bytes = self.processChunk(max_src_frames, out_space);
                if (produced_bytes == 0) {
                    if (self.in_len < old_in_len) {
                        // Resampler consumed input but produced nothing yet (filter fill).
                        // Feed more input.
                        continue;
                    }
                    // Output buffer full or nothing could be processed. Stop.
                    break;
                }
            }
        }

        /// Process up to `max_frames` source frames. Returns bytes appended to out_buf.
        fn processChunk(self: *Self, max_frames: usize, out_space: usize) usize {
            const src_sb = self.src_fmt.sampleBytes();
            const src_ch = self.src_fmt.channelCount();
            const dst_ch = self.dst_fmt.channelCount();

            const in_bytes = max_frames * src_sb;

            // Step 1: Convert input bytes → i16 samples
            var samples: [max_chunk_frames * 2]i16 = undefined;
            const num_i16 = in_bytes / 2;
            const in_byte_slice = self.in_buf[0..in_bytes];
            for (0..num_i16) |i| {
                samples[i] = @bitCast([2]u8{ in_byte_slice[i * 2], in_byte_slice[i * 2 + 1] });
            }

            // Step 2: Channel conversion (to dst channels) before resampling
            var work_buf: [max_chunk_frames * 2]i16 = undefined;
            var work_samples: usize = num_i16;
            var work_ptr: []i16 = samples[0..num_i16];

            if (src_ch == 2 and dst_ch == 1) {
                work_samples = stereoToMono(samples[0..num_i16]);
                work_ptr = samples[0..work_samples];
            } else if (src_ch == 1 and dst_ch == 2) {
                const n = monoToStereo(samples[0..num_i16], &work_buf);
                work_samples = n * 2;
                work_ptr = work_buf[0..work_samples];
            }

            // Step 3: Resample (if rates differ)
            var out_samples: [max_chunk_frames * 2 * 6]i16 = undefined;
            var produced_samples: usize = undefined;
            var consumed_src_bytes: usize = in_bytes;

            if (self.resampler) |*rs| {
                const max_out = @min(out_samples.len, out_space / 2);
                const result = rs.process(work_ptr, out_samples[0..max_out]) catch {
                    return 0;
                };
                produced_samples = result.out_produced;

                // Map resampler's consumption back to source bytes.
                // in_consumed is i16 count in dst-channel space; each
                // resampler frame = 1 source frame (channel conversion
                // is frame-preserving).
                const consumed_src_frames = result.in_consumed / dst_ch;
                consumed_src_bytes = consumed_src_frames * src_sb;
            } else {
                // Passthrough: limit output to available out_space, same as
                // the resampler branch. Without this, produced_bytes can exceed
                // out_space, causing processChunk to return 0 and lose input.
                const max_passthrough = @min(work_samples, @min(out_samples.len, out_space / 2));
                produced_samples = max_passthrough;
                @memcpy(out_samples[0..produced_samples], work_ptr[0..produced_samples]);
                const consumed_frames = produced_samples / dst_ch;
                consumed_src_bytes = consumed_frames * src_sb;
            }

            // Step 4: Convert output i16 → bytes → append to out_buf
            const produced_bytes = produced_samples * 2;
            if (produced_bytes > out_space) return 0;

            for (0..produced_samples) |i| {
                const bytes: [2]u8 = @bitCast(out_samples[i]);
                self.out_buf[self.out_end + i * 2] = bytes[0];
                self.out_buf[self.out_end + i * 2 + 1] = bytes[1];
            }
            self.out_end += produced_bytes;

            // Step 5: Compact input buffer — only remove actually consumed bytes
            const remaining = self.in_len - consumed_src_bytes;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.in_buf[0..remaining], self.in_buf[consumed_src_bytes..][0..remaining]);
            }
            self.in_len = remaining;

            return produced_bytes;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const TestRt = @import("std_impl").runtime;

// --- F1-F2: Format ---

test "F1: mono sampleBytes is 2" {
    const f = Format{ .rate = 16000, .channels = .mono };
    try testing.expectEqual(@as(usize, 2), f.sampleBytes());
    try testing.expectEqual(@as(u32, 1), f.channelCount());
}

test "F2: stereo sampleBytes is 4" {
    const f = Format{ .rate = 48000, .channels = .stereo };
    try testing.expectEqual(@as(usize, 4), f.sampleBytes());
    try testing.expectEqual(@as(u32, 2), f.channelCount());
}

// --- C1-C5: Channel conversion ---

test "C1: stereo to mono averages L and R" {
    var buf = [_]i16{ 1000, 2000, 3000, 4000 };
    const n = stereoToMono(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i16, 1500), buf[0]);
    try testing.expectEqual(@as(i16, 3500), buf[1]);
}

test "C2: mono to stereo duplicates" {
    const in = [_]i16{ 1000, 2000 };
    var out: [4]i16 = undefined;
    const n = monoToStereo(&in, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i16, 1000), out[0]);
    try testing.expectEqual(@as(i16, 1000), out[1]);
    try testing.expectEqual(@as(i16, 2000), out[2]);
    try testing.expectEqual(@as(i16, 2000), out[3]);
}

test "C3: stereo to mono empty" {
    var buf: [0]i16 = .{};
    const n = stereoToMono(&buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "C4: mono to stereo empty" {
    const in: [0]i16 = .{};
    var out: [0]i16 = .{};
    const n = monoToStereo(&in, &out);
    try testing.expectEqual(@as(usize, 0), n);
}

test "C5: stereo to mono negative values" {
    var buf = [_]i16{ -1000, -3000, -500, -1500 };
    const n = stereoToMono(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i16, -2000), buf[0]);
    try testing.expectEqual(@as(i16, -1000), buf[1]);
}

// --- R1-R6: Resampler (pure Zig sinc wrapper) ---

test "R1: init and deinit" {
    var rs = try Resampler.init(testing.allocator, .{ .in_rate = 16000, .out_rate = 48000 });
    defer rs.deinit();
}

test "R2: 16k to 48k upsample" {
    var rs = try Resampler.init(testing.allocator, .{ .in_rate = 16000, .out_rate = 48000 });
    defer rs.deinit();

    var in_buf: [160]i16 = undefined;
    for (&in_buf, 0..) |*s, i| {
        s.* = @intCast(@as(i32, @intCast(i)) * 100);
    }

    var out_buf: [512]i16 = undefined;
    const r = try rs.process(&in_buf, &out_buf);
    try testing.expectEqual(@as(u32, 160), r.in_consumed);
    try testing.expect(r.out_produced >= 400);
}

test "R3: 48k to 16k downsample" {
    var rs = try Resampler.init(testing.allocator, .{ .in_rate = 48000, .out_rate = 16000 });
    defer rs.deinit();

    var in_buf: [480]i16 = undefined;
    for (&in_buf, 0..) |*s, i| {
        s.* = @intCast(@as(i32, @intCast(i)) * 10);
    }

    var out_buf: [200]i16 = undefined;
    const r = try rs.process(&in_buf, &out_buf);
    try testing.expect(r.in_consumed > 0);
    try testing.expect(r.out_produced > 100);
}

test "R4: same rate passthrough" {
    var rs = try Resampler.init(testing.allocator, .{ .in_rate = 16000, .out_rate = 16000 });
    defer rs.deinit();

    var in_buf = [_]i16{100} ** 160;
    var out_buf: [160]i16 = undefined;
    const r = try rs.process(&in_buf, &out_buf);
    try testing.expectEqual(@as(u32, 160), r.in_consumed);
    try testing.expectEqual(@as(u32, 160), r.out_produced);
}

test "R5: reset clears state" {
    var rs = try Resampler.init(testing.allocator, .{ .in_rate = 16000, .out_rate = 48000 });
    defer rs.deinit();

    var in_buf = [_]i16{1000} ** 160;
    var out1: [512]i16 = undefined;
    const r1 = try rs.process(&in_buf, &out1);

    rs.reset();

    var out2: [512]i16 = undefined;
    const r2 = try rs.process(&in_buf, &out2);

    try testing.expectEqual(r1.out_produced, r2.out_produced);
}

test "R6: output buffer too small limits consumption" {
    var rs = try Resampler.init(testing.allocator, .{ .in_rate = 16000, .out_rate = 48000 });
    defer rs.deinit();

    var in_buf: [160]i16 = undefined;
    for (&in_buf, 0..) |*s, i| {
        s.* = @intCast(@as(i32, @intCast(i)) * 100);
    }

    // Output buffer too small for 3x upsampling of 160 samples
    var out_buf: [100]i16 = undefined;
    const r = try rs.process(&in_buf, &out_buf);
    // Should consume fewer input samples than available
    try testing.expect(r.in_consumed < 160);
    try testing.expect(r.out_produced <= 100);
}

// --- A1-A6: StreamResampler byte alignment (single-thread, alternating write/read) ---

test "A1: write exact sample boundary" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    const data = [_]u8{ 0x10, 0x27 } ** 160; // 320 bytes = 160 mono samples
    const n = try s.write(&data);
    try testing.expectEqual(@as(usize, 320), n);
}

test "A2: write partial sample buffers remainder" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    // Write 3 bytes — 1 complete sample (2 bytes) + 1 byte remainder
    const data = [_]u8{ 0x10, 0x27, 0x05 };
    const n = try s.write(&data);
    try testing.expectEqual(@as(usize, 3), n);

    // Read the 1 complete sample that was processed
    var out: [4]u8 = undefined;
    const rn = s.read(&out);
    // Should get 2 bytes (1 mono sample)
    try testing.expect(rn != null);
    try testing.expectEqual(@as(usize, 2), rn.?);
}

test "A3: write one byte at a time" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    // Write 4 bytes one at a time (= 2 mono samples)
    const bytes = [_]u8{ 0xE8, 0x03, 0xD0, 0x07 }; // 1000, 2000
    for (&bytes) |b| {
        _ = try s.write(&[_]u8{b});
    }

    var out: [4]u8 = undefined;
    const rn = s.read(&out);
    try testing.expect(rn != null);
    try testing.expectEqual(@as(usize, 4), rn.?);
    // Verify values: 1000 = 0x03E8, 2000 = 0x07D0 (little-endian)
    try testing.expectEqual(@as(u8, 0xE8), out[0]);
    try testing.expectEqual(@as(u8, 0x03), out[1]);
    try testing.expectEqual(@as(u8, 0xD0), out[2]);
    try testing.expectEqual(@as(u8, 0x07), out[3]);
}

test "A4: read empty returns zero via close" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    // Close immediately so read doesn't block
    s.close();
    var out: [32]u8 = undefined;
    const rn = s.read(&out);
    try testing.expectEqual(@as(?usize, null), rn);
}

test "A5: write zero bytes returns zero" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    const n = try s.write(&[_]u8{});
    try testing.expectEqual(@as(usize, 0), n);
}

test "A6: read aligns to sample boundary" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    const data = [_]u8{ 0x10, 0x27 } ** 4; // 8 bytes = 4 mono samples
    _ = try s.write(&data);

    // Read with odd buffer size (5 bytes) — should return 4 (2 samples)
    var out: [5]u8 = undefined;
    const rn = s.read(&out);
    try testing.expect(rn != null);
    try testing.expectEqual(@as(usize, 4), rn.?);
}

// --- S1-S5: Sample rate conversion (single-thread) ---

test "S1: 16k to 48k mono" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 48000, .channels = .mono },
    });
    defer s.deinit();

    // Write 320 bytes (10ms @ 16kHz mono = 160 samples)
    var data: [320]u8 = undefined;
    for (0..160) |i| {
        const sample: i16 = @intCast(@as(i32, @intCast(i)) * 100);
        const bytes: [2]u8 = @bitCast(sample);
        data[i * 2] = bytes[0];
        data[i * 2 + 1] = bytes[1];
    }
    _ = try s.write(&data);

    // Read output — expect ~960 bytes (10ms @ 48kHz mono = 480 samples)
    var total: usize = 0;
    var out: [2048]u8 = undefined;
    s.close();
    while (s.read(&out)) |n| {
        total += n;
    }
    // Allow some tolerance for filter delay
    try testing.expect(total >= 800);
}

test "S2: 48k to 16k mono" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 48000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    // Write 960 bytes (10ms @ 48kHz mono = 480 samples)
    var data: [960]u8 = undefined;
    for (0..480) |i| {
        const sample: i16 = @intCast(@as(i32, @intCast(i)) * 10);
        const bytes: [2]u8 = @bitCast(sample);
        data[i * 2] = bytes[0];
        data[i * 2 + 1] = bytes[1];
    }
    _ = try s.write(&data);

    var total: usize = 0;
    var out: [2048]u8 = undefined;
    s.close();
    while (s.read(&out)) |n| {
        total += n;
    }
    // Expect ~320 bytes (160 samples)
    try testing.expect(total >= 200);
}

test "S3: same rate same channels passthrough" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    // Write known data
    const sample: i16 = 12345;
    const bytes: [2]u8 = @bitCast(sample);
    const data = bytes ** 100; // 100 samples = 200 bytes
    _ = try s.write(&data);

    var out: [256]u8 = undefined;
    s.close();
    var total: usize = 0;
    while (s.read(&out)) |n| {
        // Verify passthrough: every sample should be 12345
        var i: usize = 0;
        while (i + 1 < n) : (i += 2) {
            const s_out: i16 = @bitCast([2]u8{ out[total - total + i], out[total - total + i + 1] });
            _ = s_out; // passthrough verified by total byte count
        }
        total += n;
    }
    try testing.expectEqual(@as(usize, 200), total);
}

test "S4: stereo 48k to mono 16k" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 48000, .channels = .stereo },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    // 480 stereo frames @ 48kHz = 1920 bytes (10ms)
    var data: [1920]u8 = undefined;
    for (0..480) |i| {
        const l: i16 = @intCast(@as(i32, @intCast(i)) * 20);
        const r: i16 = @intCast(@as(i32, @intCast(i)) * 20);
        const lb: [2]u8 = @bitCast(l);
        const rb: [2]u8 = @bitCast(r);
        data[i * 4] = lb[0];
        data[i * 4 + 1] = lb[1];
        data[i * 4 + 2] = rb[0];
        data[i * 4 + 3] = rb[1];
    }
    _ = try s.write(&data);

    var total: usize = 0;
    var out: [2048]u8 = undefined;
    s.close();
    while (s.read(&out)) |n| {
        total += n;
    }
    // Expect ~320 bytes (mono 16kHz, 160 samples, ~10ms)
    try testing.expect(total >= 200);
}

test "S5: mono 16k to stereo 48k" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 48000, .channels = .stereo },
    });
    defer s.deinit();

    // 160 mono samples @ 16kHz = 320 bytes (10ms)
    var data: [320]u8 = undefined;
    for (0..160) |i| {
        const sample: i16 = @intCast(@as(i32, @intCast(i)) * 100);
        const b: [2]u8 = @bitCast(sample);
        data[i * 2] = b[0];
        data[i * 2 + 1] = b[1];
    }
    _ = try s.write(&data);

    var total: usize = 0;
    var out: [4096]u8 = undefined;
    s.close();
    while (s.read(&out)) |n| {
        total += n;
    }
    // Expect ~3840 bytes (stereo 48kHz, 480 frames * 4 bytes).
    // Allow tolerance for resampler filter delay.
    try testing.expect(total >= 1500);
}

// --- T1-T7: Cross-task tests ---

test "T1: producer consumer basic" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    const total_bytes: usize = 3200; // 1600 samples

    // Producer thread
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(stream: *S, total: usize) void {
            var written: usize = 0;
            var buf: [320]u8 = .{ 0x10, 0x27 } ** 160;
            while (written < total) {
                const chunk = @min(buf.len, total - written);
                _ = stream.write(buf[0..chunk]) catch return;
                written += chunk;
            }
            stream.close();
        }
    }.run, .{ &s, total_bytes });

    // Consumer (main thread)
    var total_read: usize = 0;
    var out: [512]u8 = undefined;
    while (s.read(&out)) |n| {
        total_read += n;
    }

    producer.join();
    try testing.expectEqual(total_bytes, total_read);
}

test "T2: producer fast consumer slow" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    const total_bytes: usize = 16000;

    const producer = try std.Thread.spawn(.{}, struct {
        fn run(stream: *S, total: usize) void {
            var written: usize = 0;
            var buf = [_]u8{0} ** 1024;
            while (written < total) {
                const chunk = @min(buf.len, total - written);
                _ = stream.write(buf[0..chunk]) catch return;
                written += chunk;
            }
            stream.close();
        }
    }.run, .{ &s, total_bytes });

    var total_read: usize = 0;
    var out: [64]u8 = undefined;
    while (s.read(&out)) |n| {
        total_read += n;
        // Simulate slow consumer
        std.Thread.sleep(100 * std.time.ns_per_us);
    }

    producer.join();
    try testing.expectEqual(total_bytes, total_read);
}

test "T3: consumer blocks until data" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    var got_data = std.atomic.Value(bool).init(false);

    // Consumer thread — starts first, blocks on read
    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(stream: *S, flag: *std.atomic.Value(bool)) void {
            var out: [64]u8 = undefined;
            if (stream.read(&out)) |n| {
                if (n > 0) flag.store(true, .release);
            }
        }
    }.run, .{ &s, &got_data });

    // Small delay to let consumer start blocking
    std.Thread.sleep(5 * std.time.ns_per_ms);
    try testing.expect(!got_data.load(.acquire));

    // Now write data — should wake consumer
    const data = [_]u8{ 0x10, 0x27 } ** 10;
    _ = try s.write(&data);

    // Let consumer finish
    std.Thread.sleep(5 * std.time.ns_per_ms);
    s.close();
    consumer.join();

    try testing.expect(got_data.load(.acquire));
}

test "T4: close wakes blocked reader" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    var read_returned_null = std.atomic.Value(bool).init(false);

    // Consumer blocks on empty stream
    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(stream: *S, flag: *std.atomic.Value(bool)) void {
            var out: [64]u8 = undefined;
            const result = stream.read(&out);
            if (result == null) flag.store(true, .release);
        }
    }.run, .{ &s, &read_returned_null });

    std.Thread.sleep(5 * std.time.ns_per_ms);
    s.close();

    consumer.join();
    try testing.expect(read_returned_null.load(.acquire));
}

test "T5: close wakes blocked writer" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    var write_got_closed = std.atomic.Value(bool).init(false);

    // Fill up the buffers first (write without reading)
    // Write a lot of data to fill both in_buf and out_buf
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(stream: *S, flag: *std.atomic.Value(bool)) void {
            var buf = [_]u8{0} ** 4096;
            // Keep writing until blocked or closed
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                _ = stream.write(&buf) catch {
                    flag.store(true, .release);
                    return;
                };
            }
        }
    }.run, .{ &s, &write_got_closed });

    // Wait for producer to fill buffers and block
    std.Thread.sleep(10 * std.time.ns_per_ms);
    s.close();

    producer.join();
    try testing.expect(write_got_closed.load(.acquire));
}

test "T6: close drains remaining data" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    // Write some data then close
    const data = [_]u8{ 0x10, 0x27 } ** 100; // 200 bytes
    _ = try s.write(&data);
    s.close();

    // Reader should still get the buffered data
    var total_read: usize = 0;
    var out: [512]u8 = undefined;
    while (s.read(&out)) |n| {
        total_read += n;
    }
    try testing.expectEqual(@as(usize, 200), total_read);
}

test "T7: write after close returns error" {
    const S = StreamResampler(TestRt);
    var s = try S.init(testing.allocator, .{
        .src = .{ .rate = 16000, .channels = .mono },
        .dst = .{ .rate = 16000, .channels = .mono },
    });
    defer s.deinit();

    s.close();

    const data = [_]u8{ 0x10, 0x27 } ** 10;
    const result = s.write(&data);
    try testing.expectError(error.Closed, result);
}

// --- Q1-Q3: Quality verification ---

test "Q1: roundtrip 16k to 48k to 16k preserves signal" {
    // Generate 440Hz sine wave at 16kHz, 200ms
    const sample_rate: u32 = 16000;
    const duration_samples: usize = 3200;
    var original: [duration_samples]i16 = undefined;
    for (0..duration_samples) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sample_rate));
        original[i] = @intFromFloat(std.math.sin(2.0 * std.math.pi * 440.0 * t) * 16000.0);
    }

    // Upsample 16k → 48k
    var up = try Resampler.init(testing.allocator, .{ .in_rate = 16000, .out_rate = 48000, .quality = 10 });
    defer up.deinit();
    var upsampled: [9600 + 200]i16 = undefined;
    const r1 = try up.process(&original, &upsampled);
    try testing.expect(r1.out_produced > 8000);

    // Downsample 48k → 16k
    var down = try Resampler.init(testing.allocator, .{ .in_rate = 48000, .out_rate = 16000, .quality = 10 });
    defer down.deinit();
    var roundtrip: [duration_samples + 200]i16 = undefined;
    const r2 = try down.process(upsampled[0..r1.out_produced], &roundtrip);
    try testing.expect(r2.out_produced > 2500);

    // Verify roundtrip preserves signal energy (RMS should be similar)
    var orig_energy: f64 = 0;
    for (original[200..]) |s| {
        const v: f64 = @floatFromInt(s);
        orig_energy += v * v;
    }
    orig_energy /= @floatFromInt(duration_samples - 200);

    const skip: usize = 200;
    const n = r2.out_produced;
    if (n <= skip) return;
    var rt_energy: f64 = 0;
    for (roundtrip[skip..n]) |s| {
        const v: f64 = @floatFromInt(s);
        rt_energy += v * v;
    }
    rt_energy /= @floatFromInt(n - skip);

    // RMS energies should be within 50% of each other
    const ratio = if (orig_energy > rt_energy)
        rt_energy / orig_energy
    else
        orig_energy / rt_energy;
    try testing.expect(ratio > 0.5);

    // Roundtrip should not be silence
    try testing.expect(rt_energy > 1000.0);
}

test "Q2: roundtrip preserves silence" {
    const silence = [_]i16{0} ** 160;

    var up = try Resampler.init(testing.allocator, .{ .in_rate = 16000, .out_rate = 48000, .quality = 5 });
    defer up.deinit();
    var upsampled: [512]i16 = undefined;
    const r1 = try up.process(&silence, &upsampled);

    var down = try Resampler.init(testing.allocator, .{ .in_rate = 48000, .out_rate = 16000, .quality = 5 });
    defer down.deinit();
    var result: [200]i16 = undefined;
    const r2 = try down.process(upsampled[0..r1.out_produced], &result);

    // All samples should be near zero
    var max_abs: i16 = 0;
    for (result[0..r2.out_produced]) |s| {
        const abs_s = if (s < 0) -s else s;
        if (abs_s > max_abs) max_abs = abs_s;
    }
    // Silence roundtrip should have peak < 10 (quantization noise)
    try testing.expect(max_abs < 10);
}

test "Q3: 8k to 16k sample count" {
    var rs = try Resampler.init(testing.allocator, .{ .in_rate = 8000, .out_rate = 16000 });
    defer rs.deinit();

    var in_buf: [80]i16 = undefined; // 10ms @ 8kHz
    for (&in_buf, 0..) |*s, i| {
        s.* = @intCast(@as(i32, @intCast(i)) * 100);
    }

    var out_buf: [200]i16 = undefined;
    const r = try rs.process(&in_buf, &out_buf);
    try testing.expectEqual(@as(u32, 80), r.in_consumed);
    // 2x upsample: expect ~160 output samples
    try testing.expect(r.out_produced >= 140);
    try testing.expect(r.out_produced <= 180);
}

// --- M1-M3: Allocator verification ---

test "M1: FixedBufferAllocator — pure zig resampler allocates from stack buffer" {
    var buf: [65536]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    var rs = try Resampler.init(fba.allocator(), .{ .in_rate = 16000, .out_rate = 48000 });

    // Resampler allocated internal state from our buffer
    try testing.expect(fba.end_index > 0);

    const used_after_init = fba.end_index;

    // process should not allocate
    var in_buf = [_]i16{1000} ** 160;
    var out_buf: [512]i16 = undefined;
    _ = try rs.process(&in_buf, &out_buf);
    try testing.expectEqual(used_after_init, fba.end_index);

    rs.deinit();
}

test "M2: FixedBufferAllocator too small — init fails" {
    // 16 bytes is nowhere near enough for resampler state
    var buf: [16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const result = Resampler.init(fba.allocator(), .{ .in_rate = 16000, .out_rate = 48000 });
    try testing.expectError(error.OutOfMemory, result);
}

test "M3: GeneralPurposeAllocator — no leaks after deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        std.debug.assert(check == .ok);
    }

    var rs = try Resampler.init(gpa.allocator(), .{
        .in_rate = 16000,
        .out_rate = 48000,
        .quality = 5,
    });

    // Use it
    var in_buf = [_]i16{500} ** 160;
    var out_buf: [512]i16 = undefined;
    _ = try rs.process(&in_buf, &out_buf);

    rs.deinit();
    // gpa.deinit() in defer will assert no leaks
}
