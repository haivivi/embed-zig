const std = @import("std");
const platform = @import("platform.zig");

const log = platform.log;

pub fn run(_: anytype) void {
    log.info("[e2e] Hello World!", .{});
}

test "e2e: tier0_hello_world" {
    log.info("[e2e] Hello World!", .{});
}
