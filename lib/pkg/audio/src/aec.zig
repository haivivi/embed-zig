//! AEC — Acoustic Echo Cancellation wrapper (SpeexDSP)
//!
//! Wraps SpeexDSP's MDF (Multi-Delay Filter) echo canceller.
//! Removes speaker echo from microphone input using a reference signal.
//!
//! Two modes of operation:
//!
//! 1. **cancellation(mic, ref, out)** — caller provides time-aligned mic and ref
//! 2. **playback() + capture()** — SpeexDSP manages internal ref buffer and delay
//!
//! Mode 2 is preferred in multi-threaded pipelines where mic and speaker run
//! at slightly different rates; SpeexDSP handles the alignment internally.
//!
//! ## Usage
//!
//! ```zig
//! var aec = try Aec.init(allocator, .{});
//! defer aec.deinit();
//!
//! // Speaker task: aec.playback(&frame);
//! // Mic task:     aec.capture(&mic_buf, &clean_buf);
//! ```

const std = @import("std");
const speexdsp = @import("speexdsp");

pub const Config = struct {
    frame_size: u32 = 160,
    filter_length: u32 = 1600,
    sample_rate: u32 = 16000,
};

pub const Aec = struct {
    echo: speexdsp.EchoState,
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Aec {
        speexdsp.setAllocator(allocator);
        var echo = try speexdsp.EchoState.init(
            @intCast(config.frame_size),
            @intCast(config.filter_length),
        );
        echo.setSampleRate(@intCast(config.sample_rate));
        return .{
            .echo = echo,
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Aec) void {
        speexdsp.setAllocator(self.allocator);
        self.echo.deinit();
    }

    pub fn process(self: *Aec, mic: []const i16, ref: []const i16, out: []i16) void {
        self.echo.cancellation(mic.ptr, ref.ptr, out.ptr);
    }

    pub fn playback(self: *Aec, play: []const i16) void {
        self.echo.playback(play.ptr);
    }

    pub fn capture(self: *Aec, mic: []const i16, out: []i16) void {
        self.echo.capture(mic.ptr, out.ptr);
    }

    pub fn reset(self: *Aec) void {
        self.echo.reset();
    }

    pub fn frameSize(self: *const Aec) u32 {
        return self.config.frame_size;
    }

    pub fn filterLength(self: *const Aec) u32 {
        return self.config.filter_length;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Aec init and deinit" {
    var aec = try Aec.init(testing.allocator, .{});
    defer aec.deinit();

    try testing.expectEqual(@as(u32, 160), aec.frameSize());
    try testing.expectEqual(@as(u32, 1600), aec.filterLength());
}

test "Aec process: silence in, silence out" {
    var aec = try Aec.init(testing.allocator, .{});
    defer aec.deinit();

    const silence = [_]i16{0} ** 160;
    var out: [160]i16 = undefined;

    aec.process(&silence, &silence, &out);

    for (out) |s| {
        try testing.expect(s >= -10 and s <= 10);
    }
}

test "Aec process: identical mic and ref should cancel" {
    var aec = try Aec.init(testing.allocator, .{
        .frame_size = 160,
        .filter_length = 800,
    });
    defer aec.deinit();

    var tone: [160]i16 = undefined;
    for (&tone, 0..) |*s, i| {
        const phase: f32 = @as(f32, @floatFromInt(i)) * 500.0 / 16000.0 * 2.0 * std.math.pi;
        s.* = @intFromFloat(@sin(phase) * 10000.0);
    }

    var out: [160]i16 = undefined;

    for (0..50) |_| {
        aec.process(&tone, &tone, &out);
    }

    var in_energy: i64 = 0;
    var out_energy: i64 = 0;
    for (0..160) |i| {
        in_energy += @as(i64, tone[i]) * @as(i64, tone[i]);
        out_energy += @as(i64, out[i]) * @as(i64, out[i]);
    }

    try testing.expect(out_energy < @divTrunc(in_energy, 4));
}

test "Aec reset" {
    var aec = try Aec.init(testing.allocator, .{});
    defer aec.deinit();

    const silence = [_]i16{0} ** 160;
    var out: [160]i16 = undefined;
    aec.process(&silence, &silence, &out);

    aec.reset();

    aec.process(&silence, &silence, &out);
}

fn generateTone(buf: []i16, freq: f32, sample_rate: u32, phase_offset: usize) void {
    for (buf, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i + phase_offset)) / @as(f32, @floatFromInt(sample_rate));
        s.* = @intFromFloat(@sin(t * freq * 2.0 * std.math.pi) * 10000.0);
    }
}

fn frameRmsEnergy(buf: []const i16) f64 {
    var e: f64 = 0;
    for (buf) |s| {
        const v: f64 = @floatFromInt(s);
        e += v * v;
    }
    return e / @as(f64, @floatFromInt(buf.len));
}

test "Aec playback/capture mode" {
    var aec = try Aec.init(testing.allocator, .{
        .frame_size = 160,
        .filter_length = 1600,
    });
    defer aec.deinit();

    var tone: [160]i16 = undefined;
    var out: [160]i16 = undefined;

    // Converge the filter
    for (0..100) |frame| {
        generateTone(&tone, 500.0, 16000, frame * 160);
        aec.playback(&tone);
        aec.capture(&tone, &out);
    }

    // After convergence, output should have much less energy than input
    generateTone(&tone, 500.0, 16000, 100 * 160);
    aec.playback(&tone);
    aec.capture(&tone, &out);

    const in_e = frameRmsEnergy(&tone);
    const out_e = frameRmsEnergy(&out);

    try testing.expect(in_e > 0);
    try testing.expect(out_e < in_e / 4);
}

test "Aec ERLE measurement (100-frame convergence)" {
    var aec = try Aec.init(testing.allocator, .{
        .frame_size = 160,
        .filter_length = 1600,
    });
    defer aec.deinit();

    var tone: [160]i16 = undefined;
    var out: [160]i16 = undefined;
    var early_energy: f64 = 0;
    var late_energy: f64 = 0;

    for (0..150) |frame| {
        generateTone(&tone, 440.0, 16000, frame * 160);
        aec.process(&tone, &tone, &out);

        const e = frameRmsEnergy(&out);
        if (frame < 10) early_energy += e;
        if (frame >= 140) late_energy += e;
    }

    // Late energy (after convergence) should be much lower than early
    try testing.expect(late_energy < early_energy / 2);
}

test "Aec reset after adaptation loses convergence" {
    var aec = try Aec.init(testing.allocator, .{
        .frame_size = 160,
        .filter_length = 800,
    });
    defer aec.deinit();

    var tone: [160]i16 = undefined;
    var out: [160]i16 = undefined;

    // Converge
    for (0..100) |frame| {
        generateTone(&tone, 440.0, 16000, frame * 160);
        aec.process(&tone, &tone, &out);
    }

    const converged_energy = frameRmsEnergy(&out);

    // Reset
    aec.reset();

    // First frame after reset should have higher energy (lost convergence)
    generateTone(&tone, 440.0, 16000, 0);
    aec.process(&tone, &tone, &out);
    const reset_energy = frameRmsEnergy(&out);

    try testing.expect(reset_energy > converged_energy);
}

test "E2E-10: playback/capture vs cancellation consistency" {
    var aec_pc = try Aec.init(testing.allocator, .{
        .frame_size = 160,
        .filter_length = 800,
    });
    defer aec_pc.deinit();

    var aec_cancel = try Aec.init(testing.allocator, .{
        .frame_size = 160,
        .filter_length = 800,
    });
    defer aec_cancel.deinit();

    var tone: [160]i16 = undefined;
    var out_pc: [160]i16 = undefined;
    var out_cancel: [160]i16 = undefined;

    // Run both modes with same data for convergence
    for (0..150) |frame| {
        generateTone(&tone, 440.0, 16000, frame * 160);
        aec_pc.playback(&tone);
        aec_pc.capture(&tone, &out_pc);
        aec_cancel.process(&tone, &tone, &out_cancel);
    }

    // Both should achieve some cancellation compared to input
    const in_e = frameRmsEnergy(&tone);
    const pc_e = frameRmsEnergy(&out_pc);
    const cancel_e = frameRmsEnergy(&out_cancel);

    // cancellation() mode should reduce significantly
    try testing.expect(cancel_e < in_e / 2);
    // playback/capture mode may not converge as well (internal buffering differs),
    // but should still reduce below input
    try testing.expect(pc_e < in_e);
}
