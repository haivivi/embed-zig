//! Time Interface Definition
//!
//! Provides compile-time validation for Time interface.
//!
//! Platform implementations:
//! - ESP32: lib/platform/esp/idf/src/runtime.zig
//! - Zig std: lib/platform/std/src/impl/runtime.zig
//!
//! Usage:
//! ```zig
//! const Time = trait.time.from(hw.time);
//! Time.sleepMs(100);
//! const now = Time.getTimeMs();
//! ```

const std = @import("std");

/// Check if type implements Time interface
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    const BaseType = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
    if (!@hasDecl(BaseType, "sleepMs") or !@hasDecl(BaseType, "getTimeMs")) return false;
    // Verify signatures
    const sleepMs_ok = @TypeOf(&BaseType.sleepMs) == *const fn (u32) void;
    const getTimeMs_ok = @TypeOf(&BaseType.getTimeMs) == *const fn () u64;
    return sleepMs_ok and getTimeMs_ok;
}

/// Time Interface - comptime validates and returns Impl
pub fn from(comptime Impl: type) type {
    comptime {
        // Handle pointer types to avoid shallow copy
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };
        _ = @as(*const fn (u32) void, &BaseType.sleepMs);
        _ = @as(*const fn () u64, &BaseType.getTimeMs);
    }
    return Impl;
}

// =========== Tests ===========

test "Time() returns interface type" {
    const MockImpl = struct {
        pub fn sleepMs(_: u32) void {}
        pub fn getTimeMs() u64 {
            return 12345;
        }
    };

    // Get Time interface type
    const TestTime = from(MockImpl);

    // Can call methods
    TestTime.sleepMs(100);
    const t = TestTime.getTimeMs();
    try std.testing.expectEqual(@as(u64, 12345), t);
}
