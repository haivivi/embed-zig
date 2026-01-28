//! Random Number Generator Interface Definition
//!
//! Provides compile-time validation for RNG interface.
//! Used by TLS for generating random bytes (client random, key material, etc.)
//!
//! Platform implementations:
//! - ESP32: lib/esp/src/sal/rng.zig (hardware RNG)
//! - Zig std: lib/std/src/sal/rng.zig (std.crypto.random)
//!
//! Usage:
//! ```zig
//! const Rng = trait.rng.from(hw.rng);
//! var buf: [32]u8 = undefined;
//! Rng.fill(&buf);
//! ```

const std = @import("std");

/// RNG error types
pub const Error = error{
    /// RNG source unavailable or failed
    RngFailed,
};

/// Check if type implements RNG interface
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    const BaseType = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
    if (!@hasDecl(BaseType, "fill")) return false;
    // Verify signature: fill([]u8) void or fill([]u8) Error!void
    const fill_info = @typeInfo(@TypeOf(BaseType.fill));
    if (fill_info != .@"fn") return false;
    const params = fill_info.@"fn".params;
    if (params.len != 1) return false;
    // Check first param is []u8
    if (params[0].type) |param_type| {
        if (param_type != []u8) return false;
    } else return false;
    return true;
}

/// RNG Interface - comptime validates and returns Impl
pub fn from(comptime Impl: type) type {
    comptime {
        // Handle pointer types to avoid shallow copy
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };
        // Validate fill function exists with correct signature
        if (!@hasDecl(BaseType, "fill")) {
            @compileError("RNG implementation must have fill([]u8) function");
        }
    }
    return Impl;
}

// =========== Default Implementations ===========

/// Standard library RNG (uses std.crypto.random)
pub const StdRng = struct {
    pub fn fill(buf: []u8) void {
        std.crypto.random.bytes(buf);
    }
};

// =========== Tests ===========

test "RNG interface validation" {
    const MockRng = struct {
        pub fn fill(buf: []u8) void {
            for (buf) |*b| b.* = 0xAB;
        }
    };

    // Get RNG interface type
    const TestRng = from(MockRng);

    // Can call methods
    var buf: [16]u8 = undefined;
    TestRng.fill(&buf);
    try std.testing.expectEqual(@as(u8, 0xAB), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), buf[15]);
}

test "is() validates RNG interface" {
    const ValidRng = struct {
        pub fn fill(_: []u8) void {}
    };
    const InvalidRng = struct {
        pub fn notFill(_: []u8) void {}
    };
    const NotAStruct = u32;

    try std.testing.expect(is(ValidRng));
    try std.testing.expect(!is(InvalidRng));
    try std.testing.expect(!is(NotAStruct));
}

test "StdRng produces random bytes" {
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;

    StdRng.fill(&buf1);
    StdRng.fill(&buf2);

    // Extremely unlikely to be equal if truly random
    try std.testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}
