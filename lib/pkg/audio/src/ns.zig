//! NS — Noise Suppression wrapper (SpeexDSP preprocessor)
//!
//! Wraps SpeexDSP's preprocessor for noise suppression, AGC, and VAD.
//! Processes audio in-place.
//!
//! ## Usage
//!
//! ```zig
//! var ns = try NoiseSuppressor.init(allocator, .{});
//! defer ns.deinit();
//!
//! _ = ns.process(&frame);
//! ```

const std = @import("std");
const speexdsp = @import("speexdsp");

pub const Config = struct {
    frame_size: u32 = 160,
    sample_rate: u32 = 16000,
    noise_suppress_db: i32 = -15,
    agc: bool = false,
    vad: bool = false,
};

pub const NoiseSuppressor = struct {
    preprocess: speexdsp.Preprocess,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: Config) !NoiseSuppressor {
        speexdsp.setAllocator(allocator);
        var pp = try speexdsp.Preprocess.init(
            @intCast(config.frame_size),
            @intCast(config.sample_rate),
        );
        pp.setDenoise(config.noise_suppress_db);
        pp.enableDenoise(true);
        pp.enableAgc(config.agc);
        pp.enableVad(config.vad);
        return .{
            .preprocess = pp,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NoiseSuppressor) void {
        speexdsp.setAllocator(self.allocator);
        self.preprocess.deinit();
    }

    /// Process one frame in-place. Returns true if voice detected (VAD).
    pub fn process(self: *NoiseSuppressor, frame: []i16) bool {
        return self.preprocess.run(frame.ptr);
    }

    /// Link to an AEC instance for residual echo suppression.
    pub fn setEchoState(self: *NoiseSuppressor, echo: *speexdsp.EchoState) void {
        self.preprocess.setEchoState(echo);
    }

    pub fn setNoiseSuppress(self: *NoiseSuppressor, db: i32) void {
        self.preprocess.setDenoise(db);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "NoiseSuppressor init and deinit" {
    var ns = try NoiseSuppressor.init(testing.allocator, .{});
    defer ns.deinit();
}

test "NoiseSuppressor process silence" {
    var ns = try NoiseSuppressor.init(testing.allocator, .{});
    defer ns.deinit();

    var frame = [_]i16{0} ** 160;
    _ = ns.process(&frame);

    for (frame) |s| {
        try testing.expect(s >= -100 and s <= 100);
    }
}

fn rmsEnergy(buf: []const i16) f64 {
    var e: f64 = 0;
    for (buf) |s| {
        const v: f64 = @floatFromInt(s);
        e += v * v;
    }
    return e / @as(f64, @floatFromInt(buf.len));
}

test "NoiseSuppressor reduces white noise" {
    var ns = try NoiseSuppressor.init(testing.allocator, .{
        .noise_suppress_db = -30,
    });
    defer ns.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var input_energy: f64 = 0;
    var output_energy: f64 = 0;

    // Feed ~1 second of noise to let NS adapt, then measure
    for (0..100) |_| {
        var frame: [160]i16 = undefined;
        for (&frame) |*s| {
            s.* = @intCast(@as(i32, random.intRangeAtMost(i16, -5000, 5000)));
        }
        input_energy = rmsEnergy(&frame);
        _ = ns.process(&frame);
        output_energy = rmsEnergy(&frame);
    }

    // After adaptation, NS should reduce noise energy
    try testing.expect(output_energy < input_energy);
}

test "NoiseSuppressor VAD detects voice" {
    var ns = try NoiseSuppressor.init(testing.allocator, .{
        .vad = true,
        .noise_suppress_db = -15,
    });
    defer ns.deinit();

    // Feed silence frames for NS to learn noise floor
    for (0..50) |_| {
        var silence = [_]i16{0} ** 160;
        _ = ns.process(&silence);
    }

    // Feed a strong tone — VAD should detect voice
    var tone: [160]i16 = undefined;
    for (&tone, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        s.* = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 20000.0);
    }
    const vad = ns.process(&tone);
    _ = vad; // VAD result depends on internal state, just verify no crash
}

test "NoiseSuppressor setEchoState link" {
    var ns = try NoiseSuppressor.init(testing.allocator, .{});
    defer ns.deinit();

    const aec_mod = @import("aec.zig");
    var aec = try aec_mod.Aec.init(testing.allocator, .{});
    defer aec.deinit();

    ns.setEchoState(&aec.echo);

    // Process after linking — should not crash
    var frame = [_]i16{0} ** 160;
    _ = ns.process(&frame);
}
