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
