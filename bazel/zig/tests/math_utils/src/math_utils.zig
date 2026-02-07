//! Math utils — depends on base module.
//! Tests transitive dependency resolution and cache propagation.

const base = @import("base");

pub fn clamp(val: i32, min_val: i32, max_val: i32) i32 {
    if (val < min_val) return min_val;
    if (val > max_val) return max_val;
    return val;
}

pub fn abs(x: i32) i32 {
    return if (x < 0) base.negate(x) else x;
}

pub fn sum_of_squares(a: i32, b: i32) i32 {
    return base.add(base.multiply(a, a), base.multiply(b, b));
}

test "clamp" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 5), clamp(5, 0, 10));
    try std.testing.expectEqual(@as(i32, 0), clamp(-3, 0, 10));
    try std.testing.expectEqual(@as(i32, 10), clamp(15, 0, 10));
}

test "abs uses base.negate" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 5), abs(-5));
    try std.testing.expectEqual(@as(i32, 5), abs(5));
    try std.testing.expectEqual(@as(i32, 0), abs(0));
}

test "sum_of_squares uses base.add and base.multiply" {
    const std = @import("std");
    // 3^2 + 4^2 = 9 + 16 = 25
    try std.testing.expectEqual(@as(i32, 25), sum_of_squares(3, 4));
    try std.testing.expectEqual(@as(i32, 0), sum_of_squares(0, 0));
}
