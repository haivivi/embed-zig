const std = @import("std");
const opus_codec = @import("opus_codec.zig");

pub const log = struct {
    pub fn info(comptime fmt: []const u8, args: anytype) void { std.debug.print("[INFO] " ++ fmt ++ "\n", args); }
    pub fn err(comptime fmt: []const u8, args: anytype) void { std.debug.print("[ERR]  " ++ fmt ++ "\n", args); }
    pub fn warn(comptime fmt: []const u8, args: anytype) void { std.debug.print("[WARN] " ++ fmt ++ "\n", args); }
    pub fn debug(comptime fmt: []const u8, args: anytype) void { std.debug.print("[DBG]  " ++ fmt ++ "\n", args); }
};

pub const Codec = opus_codec;
