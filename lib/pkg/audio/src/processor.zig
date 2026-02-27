//! Audio Processor abstraction — unified AEC/NS entry
//!
//! Engine-facing contract:
//! - `init(allocator, config) !Self`
//! - `deinit(self)`
//! - `process(self, mic, ref, out)`
//! - optional `reset(self)`
//!
//! Platform/algorithm specific implementations (ESP/BK/AEC3) should
//! implement this contract and keep algorithm details internal.

const std = @import("std");

pub const Config = struct {
    frame_size: u32 = 160,
    sample_rate: u32 = 16000,
    aec_filter_length: u32 = 8000,
    noise_suppress_db: i32 = -30,
    enable_aec: bool = true,
    enable_ns: bool = true,
};

/// Compile-time contract checker for processor implementations.
pub fn validate(comptime T: type) void {
    comptime {
        _ = @as(*const fn (std.mem.Allocator, Config) anyerror!T, &T.init);
        _ = @as(*const fn (*T) void, &T.deinit);
        _ = @as(*const fn (*T, []const i16, []const i16, []i16) void, &T.process);
    }
}

/// Default pure-Zig fallback processor.
///
/// Behavior: passthrough microphone samples to output, ignoring ref.
/// This keeps Engine independent from any external DSP backend.
pub const PassthroughProcessor = struct {
    pub fn init(_: std.mem.Allocator, _: Config) !PassthroughProcessor {
        return .{};
    }

    pub fn deinit(_: *PassthroughProcessor) void {}

    pub fn process(_: *PassthroughProcessor, mic: []const i16, _: []const i16, out: []i16) void {
        @memcpy(out, mic);
    }

    pub fn reset(_: *PassthroughProcessor) void {}
};

test "processor contract validate default impl" {
    validate(PassthroughProcessor);
}
