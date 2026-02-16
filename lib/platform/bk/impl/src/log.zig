//! Log Implementation for BK7258

const std = @import("std");
const armino = @import("../../armino/src/armino.zig");

pub const Log = struct {
    const tag: [*:0]const u8 = "app";

    pub fn info(comptime fmt: []const u8, args: anytype) void {
        armino.log.logFmt(tag, fmt, args);
    }
    pub fn err(comptime fmt: []const u8, args: anytype) void {
        armino.log.errFmt(tag, fmt, args);
    }
    pub fn warn(comptime fmt: []const u8, args: anytype) void {
        armino.log.warnFmt(tag, fmt, args);
    }
    pub fn debug(comptime fmt: []const u8, args: anytype) void {
        armino.log.logFmt(tag, fmt, args);
    }
};

pub fn scoped(comptime scope: []const u8) type {
    return struct {
        const scoped_tag: [*:0]const u8 = scope ++ "\x00";

        pub fn info(comptime fmt: []const u8, args: anytype) void {
            armino.log.logFmt(scoped_tag, fmt, args);
        }
        pub fn err(comptime fmt: []const u8, args: anytype) void {
            armino.log.errFmt(scoped_tag, fmt, args);
        }
        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            armino.log.warnFmt(scoped_tag, fmt, args);
        }
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            armino.log.logFmt(scoped_tag, fmt, args);
        }
    };
}

pub fn stdLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = if (scope != .default) "(" ++ @tagName(scope) ++ "): " else "";
    const tag: [*:0]const u8 = "zig";
    switch (level) {
        .err => armino.log.errFmt(tag, scope_prefix ++ format, args),
        .warn => armino.log.warnFmt(tag, scope_prefix ++ format, args),
        .info => armino.log.logFmt(tag, scope_prefix ++ format, args),
        .debug => armino.log.logFmt(tag, scope_prefix ++ format, args),
    }
}
