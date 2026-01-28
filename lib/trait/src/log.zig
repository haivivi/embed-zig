//! Log Interface Definition
//!
//! Provides compile-time validation for Log interface.
//!
//! Platform implementations:
//! - ESP32: board provides log via idf or std.log
//! - Simulator: raysim provides log
//! - Native: std.log
//!
//! Usage:
//! ```zig
//! const Log = trait.log.from(hw.log);
//! Log.info("started", .{});
//! ```

const std = @import("std");

/// Check if type implements Log interface
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    const BaseType = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
    return @hasDecl(BaseType, "info") and
        @hasDecl(BaseType, "err") and
        @hasDecl(BaseType, "warn") and
        @hasDecl(BaseType, "debug");
}

/// Log Interface - comptime validates and returns Impl
pub fn from(comptime Impl: type) type {
    comptime {
        // Handle pointer types to avoid shallow copy
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };
        // Validate by checking method existence (can't call variadic functions at comptime)
        _ = @as(@TypeOf(&BaseType.info), &BaseType.info);
        _ = @as(@TypeOf(&BaseType.err), &BaseType.err);
        _ = @as(@TypeOf(&BaseType.warn), &BaseType.warn);
        _ = @as(@TypeOf(&BaseType.debug), &BaseType.debug);
    }
    return Impl;
}

// =========== Tests ===========

test "Log interface validation" {
    const MockLog = struct {
        pub fn info(_: []const u8, _: anytype) void {}
        pub fn err(_: []const u8, _: anytype) void {}
        pub fn warn(_: []const u8, _: anytype) void {}
        pub fn debug(_: []const u8, _: anytype) void {}
    };

    const Log = from(MockLog);
    _ = Log;
}
