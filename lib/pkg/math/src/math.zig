//! Math utility functions for embedded systems
//!
//! This module provides optimized math functions that avoid std.math operations
//! which may use 128-bit operations not supported on all targets.

const std = @import("std");

/// Simple atan2 approximation (avoids std.math.atan2 which may use 128-bit ops)
/// Uses a polynomial approximation that is accurate to within a few degrees.
pub fn approxAtan2(y: f32, x: f32) f32 {
    const abs_x = @abs(x);
    const abs_y = @abs(y);

    // Handle edge cases
    if (abs_x < 0.0001 and abs_y < 0.0001) return 0;
    if (abs_x < 0.0001) return if (y > 0) std.math.pi / 2.0 else -std.math.pi / 2.0;

    // Fast polynomial approximation
    const a = @min(abs_x, abs_y) / @max(abs_x, abs_y);
    const s = a * a;
    var r = ((-0.0464964749 * s + 0.15931422) * s - 0.327622764) * s * a + a;

    if (abs_y > abs_x) r = std.math.pi / 2.0 - r;
    if (x < 0) r = std.math.pi - r;
    if (y < 0) r = -r;

    return r;
}

test "approxAtan2 basic" {
    const pi = std.math.pi;
    const tolerance: f32 = 0.01;

    // Test quadrant angles
    try std.testing.expectApproxEqAbs(@as(f32, 0), approxAtan2(0, 1), tolerance);
    try std.testing.expectApproxEqAbs(pi / 2.0, approxAtan2(1, 0), tolerance);
    try std.testing.expectApproxEqAbs(pi, approxAtan2(0, -1), tolerance);
    try std.testing.expectApproxEqAbs(-pi / 2.0, approxAtan2(-1, 0), tolerance);
}
