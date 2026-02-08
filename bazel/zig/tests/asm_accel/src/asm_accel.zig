//! ASM accelerated module — Zig + Assembly (aarch64).
//! Depends on base to test ASM + Zig dep combination.

const base = @import("base");
const c = @cImport(@cInclude("fast_add.h"));

/// Add two numbers using assembly implementation.
pub fn fast_add(a: i64, b: i64) i64 {
    return c.fast_add(a, b);
}

/// Combine ASM fast_add with base module's multiply.
pub fn multiply_then_add(x: i32, y: i32, offset: i64) i64 {
    const product: i64 = @intCast(base.multiply(x, y));
    return fast_add(product, offset);
}

test "fast_add asm" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i64, 42), fast_add(20, 22));
    try std.testing.expectEqual(@as(i64, 0), fast_add(-5, 5));
    try std.testing.expectEqual(@as(i64, -10), fast_add(-3, -7));
}

test "multiply_then_add combines base + asm" {
    const std = @import("std");
    // 3 * 4 + 100 = 112
    try std.testing.expectEqual(@as(i64, 112), multiply_then_add(3, 4, 100));
}
