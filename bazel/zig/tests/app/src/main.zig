//! App binary — full dependency chain test (pure Zig).
//! Tests zig_binary with transitive deps: math_utils → base (2 layers)

const std = @import("std");
const math = @import("math_utils");
const base = @import("base");

pub fn main() void {
    // Exercise the full chain
    const a = base.add(10, 20);
    const b = math.sum_of_squares(3, 4);
    const c = math.clamp(b, 0, 20);

    std.debug.print("base.add(10,20) = {d}\n", .{a});
    std.debug.print("math.sum_of_squares(3,4) = {d}\n", .{b});
    std.debug.print("math.clamp({d}, 0, 20) = {d}\n", .{ b, c });
}
