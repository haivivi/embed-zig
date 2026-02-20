//! Shared test utilities for audio module tests.
//!
//! Provides:
//! - Audio signal generators (sine, white noise)
//! - Energy analysis (RMS, dB, ERLE)
//! - Frequency analysis (Goertzel algorithm)
//! - Loopback devices (LoopbackSpeaker + LoopbackMic) for software AEC testing

const std = @import("std");

// ============================================================================
// Signal generators
// ============================================================================

pub fn generateSine(buf: []i16, freq: f32, amplitude: f32, sample_rate: u32, phase_offset: usize) void {
    for (buf, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i + phase_offset)) / @as(f32, @floatFromInt(sample_rate));
        s.* = @intFromFloat(@sin(t * freq * 2.0 * std.math.pi) * amplitude);
    }
}

pub fn generateWhiteNoise(buf: []i16, amplitude: i16, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    for (buf) |*s| {
        s.* = rng.intRangeAtMost(i16, -amplitude, amplitude);
    }
}

// ============================================================================
// Energy analysis
// ============================================================================

pub fn rmsEnergy(samples: []const i16) f64 {
    var sum: f64 = 0;
    for (samples) |s| {
        const f: f64 = @floatFromInt(s);
        sum += f * f;
    }
    return @sqrt(sum / @as(f64, @floatFromInt(samples.len)));
}

pub fn energyDb(rms: f64) f64 {
    if (rms < 1.0) return -100.0;
    return 20.0 * @log10(rms / 32768.0);
}

pub fn erleDb(echo_rms: f64, clean_rms: f64) f64 {
    if (clean_rms < 1.0) return 60.0;
    return 20.0 * @log10(echo_rms / clean_rms);
}

// ============================================================================
// Frequency analysis (Goertzel algorithm)
// ============================================================================

pub fn goertzelPower(samples: []const i16, target_freq: f64, sample_rate: f64) f64 {
    const n: f64 = @floatFromInt(samples.len);
    const k = @round(target_freq * n / sample_rate);
    const w = 2.0 * std.math.pi * k / n;
    const coeff = 2.0 * @cos(w);
    var s0: f64 = 0;
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (samples) |sample| {
        s0 = @as(f64, @floatFromInt(sample)) + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

// ============================================================================
// LoopbackSpeaker — satisfies hal.mono_speaker Driver contract
// ============================================================================

pub const LoopbackSpeaker = struct {
    ring: []i16,
    cap: usize,
    write_pos: usize = 0,
    read_pos: usize = 0,
    mutex: std.Thread.Mutex = .{},
    write_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !LoopbackSpeaker {
        const ring = try allocator.alloc(i16, size);
        @memset(ring, 0);
        return .{ .ring = ring, .cap = size, .allocator = allocator };
    }

    pub fn deinit(self: *LoopbackSpeaker) void {
        self.allocator.free(self.ring);
    }

    pub fn write(self: *LoopbackSpeaker, buffer: []const i16) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (buffer) |s| {
            self.ring[self.write_pos % self.cap] = s;
            self.write_pos += 1;
        }
        _ = self.write_count.fetchAdd(1, .acq_rel);
        return buffer.len;
    }

    /// Pop one sample from the ring (called by LoopbackMic under speaker mutex).
    fn pop(self: *LoopbackSpeaker) ?i16 {
        if (self.read_pos >= self.write_pos) return null;
        const s = self.ring[self.read_pos % self.cap];
        self.read_pos += 1;
        return s;
    }
};

// ============================================================================
// LoopbackMic — satisfies hal.mic Driver contract
// ============================================================================

pub const LoopbackMic = struct {
    speaker: *LoopbackSpeaker,
    echo_gain: f32 = 0.8,
    delay_samples: usize = 320,
    inject_fn: ?*const fn (usize) i16 = null,
    total_read: usize = 0,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    delay_buf: [640]i16 = [_]i16{0} ** 640,
    delay_pos: usize = 0,

    /// Raw echo energy accumulator (for ERLE calculation)
    raw_echo_energy: f64 = 0,

    pub fn read(self: *LoopbackMic, buf: []i16) !usize {
        if (self.stopped.load(.acquire)) return 0;

        self.speaker.mutex.lock();
        defer self.speaker.mutex.unlock();

        for (buf, 0..) |*out, i| {
            const speaker_sample: i16 = self.speaker.pop() orelse 0;

            // Delay buffer simulates acoustic propagation
            const delayed = self.delay_buf[self.delay_pos];
            self.delay_buf[self.delay_pos] = speaker_sample;
            self.delay_pos = (self.delay_pos + 1) % self.delay_samples;

            // Echo = delayed speaker * gain
            const echo: i32 = @intFromFloat(@as(f32, @floatFromInt(delayed)) * self.echo_gain);

            // Accumulate raw echo energy for ERLE measurement
            self.raw_echo_energy += @as(f64, @floatFromInt(echo)) * @as(f64, @floatFromInt(echo));

            // Inject near-end signal if present
            const inject: i32 = if (self.inject_fn) |f| f(self.total_read + i) else 0;

            const mixed = std.math.clamp(echo + inject, -32768, 32767);
            out.* = @intCast(mixed);
        }
        self.total_read += buf.len;

        // Simulate real mic DMA timing
        std.Thread.sleep(buf.len * std.time.ns_per_s / 16000);
        return buf.len;
    }
};

// ============================================================================
// Tests for test_utils itself
// ============================================================================

const testing = std.testing;

test "generateSine produces expected amplitude" {
    var buf: [160]i16 = undefined;
    generateSine(&buf, 440.0, 10000.0, 16000, 0);

    var max: i16 = 0;
    for (buf) |s| {
        const abs: i16 = if (s < 0) -s else s;
        if (abs > max) max = abs;
    }
    try testing.expect(max >= 9000);
    try testing.expect(max <= 10001);
}

test "rmsEnergy of silence is zero" {
    const silence = [_]i16{0} ** 160;
    try testing.expectEqual(@as(f64, 0.0), rmsEnergy(&silence));
}

test "rmsEnergy of constant signal" {
    const buf = [_]i16{1000} ** 160;
    const rms = rmsEnergy(&buf);
    try testing.expect(rms >= 999.0 and rms <= 1001.0);
}

test "goertzelPower detects frequency" {
    var buf: [1600]i16 = undefined; // 100ms @ 16kHz
    generateSine(&buf, 440.0, 10000.0, 16000, 0);

    const power_440 = goertzelPower(&buf, 440.0, 16000.0);
    const power_880 = goertzelPower(&buf, 880.0, 16000.0);

    // 440Hz should have much more power than 880Hz
    try testing.expect(power_440 > power_880 * 100);
}

test "LoopbackSpeaker write and pop" {
    var speaker = try LoopbackSpeaker.init(testing.allocator, 256);
    defer speaker.deinit();

    const data = [_]i16{ 100, 200, 300 };
    _ = try speaker.write(&data);

    speaker.mutex.lock();
    defer speaker.mutex.unlock();
    try testing.expectEqual(@as(i16, 100), speaker.pop().?);
    try testing.expectEqual(@as(i16, 200), speaker.pop().?);
    try testing.expectEqual(@as(i16, 300), speaker.pop().?);
    try testing.expectEqual(@as(?i16, null), speaker.pop());
}
