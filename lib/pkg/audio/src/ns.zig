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
