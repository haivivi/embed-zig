//! Base module — pure Zig, zero dependencies.
//! Provides simple arithmetic used by downstream test packages.

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn multiply(a: i32, b: i32) i32 {
    return a * b;
}

pub fn negate(x: i32) i32 {
    return -x;
}

test "add" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 5), add(2, 3));
    try std.testing.expectEqual(@as(i32, 0), add(-1, 1));
    try std.testing.expectEqual(@as(i32, -3), add(-1, -2));
}

test "multiply" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 6), multiply(2, 3));
    try std.testing.expectEqual(@as(i32, 0), multiply(0, 100));
    try std.testing.expectEqual(@as(i32, -6), multiply(-2, 3));
}

test "negate" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, -5), negate(5));
    try std.testing.expectEqual(@as(i32, 5), negate(-5));
    try std.testing.expectEqual(@as(i32, 0), negate(0));
}
