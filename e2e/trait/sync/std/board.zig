//! std board for e2e trait/sync
//!
//! Provides log, time, and runtime using Zig standard library.

const std = @import("std");
const std_impl = @import("std_impl");

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

    pub fn getTimeMs() u64 {
        return std_impl.time.nowMs();
    }
};

pub const runtime = std_impl.runtime;
