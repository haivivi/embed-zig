//! sim board implementation for tier2_audio_engine

const std = @import("std");
const std_impl = @import("std_impl");
const audio = @import("audio");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;

pub const log = struct {
    pub fn info(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[INFO] " ++ fmt ++ "\n", args);
    }
    pub fn err(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[ERR]  " ++ fmt ++ "\n", args);
    }
    pub fn warn(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[WARN] " ++ fmt ++ "\n", args);
    }
    pub fn debug(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[DBG]  " ++ fmt ++ "\n", args);
    }
};

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        std_impl.time.sleepMs(ms);
    }
    pub fn nowMs() u64 {
        return std_impl.time.nowMs();
    }
};

pub const runtime = std_impl.runtime;
pub const engine_frame_size: u32 = FRAME_SIZE;

pub fn allocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

const SimAudioType = audio.sim_audio.SimAudio(.{
    .frame_size = FRAME_SIZE,
    .sample_rate = SAMPLE_RATE,
    .echo_delay_samples = 0,
    .echo_gain = 0.0,
    .has_hardware_loopback = false,
    .ref_aligned_with_echo = true,
    .ambient_noise_rms = 0,
});

pub const DuplexAudio = struct {
    pub const Mic = SimAudioType.Mic;
    pub const Speaker = SimAudioType.Speaker;
    pub const RefReader = SimAudioType.RefReader;

    sim: SimAudioType,

    pub fn init(alloc: std.mem.Allocator) !DuplexAudio {
        _ = alloc;
        var d = DuplexAudio{ .sim = SimAudioType.init() };
        try d.sim.start();
        return d;
    }

    pub fn stop(self: *DuplexAudio) void {
        self.sim.stop();
    }

    pub fn mic(self: *DuplexAudio) Mic {
        return self.sim.mic();
    }

    pub fn speaker(self: *DuplexAudio) Speaker {
        return self.sim.speaker();
    }

    pub fn refReader(self: *DuplexAudio) RefReader {
        return self.sim.refReader();
    }
};

pub fn initAudio() !void {}

pub fn deinitAudio() void {}
