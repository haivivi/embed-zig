//! std board implementation for tier2_audio_engine

const std = @import("std");
const std_impl = @import("std_impl");
const pa = @import("portaudio");

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
pub const DuplexAudio = std_impl.audio_engine.DuplexAudio;
pub const engine_frame_size: u32 = 160;

pub fn allocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

pub fn initAudio() !void {
    try pa.init();
}

pub fn deinitAudio() void {
    pa.deinit();
}
