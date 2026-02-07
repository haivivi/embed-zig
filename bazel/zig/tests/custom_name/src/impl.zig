//! Custom name test — verifies main and module_name overrides.
//! Root source is src/impl.zig (not src/custom_name.zig).
//! Module name is "mylib" (not "custom_name").

pub const version: u32 = 1;

pub fn greet() []const u8 {
    return "hello from mylib";
}

test "version" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 1), version);
}

test "greet" {
    const std = @import("std");
    try std.testing.expectEqualStrings("hello from mylib", greet());
}
