//! Log Interface Definition
//!
//! Provides compile-time validation for Log interface.
//!
//! Platform implementations:
//! - ESP32: board provides log via idf or std.log
//! - Simulator: websim provides log
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
        validateLevel(BaseType, "info");
        validateLevel(BaseType, "err");
        validateLevel(BaseType, "warn");
        validateLevel(BaseType, "debug");
    }
    return Impl;
}

fn validateLevel(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name)) {
        @compileError("Log missing method: " ++ name);
    }

    const fn_info = @typeInfo(@TypeOf(@field(T, name)));
    if (fn_info != .@"fn") {
        @compileError("Log method must be function: " ++ name);
    }

    const f = fn_info.@"fn";
    if (f.params.len < 2) {
        @compileError("Log method must accept format and args: " ++ name);
    }
    if (f.params[0].type != []const u8) {
        @compileError("Log method first param must be []const u8: " ++ name);
    }
    if (f.return_type == null or f.return_type.? != void) {
        @compileError("Log method return type must be void: " ++ name);
    }
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
