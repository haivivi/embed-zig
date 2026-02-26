const std = @import("std");
const opus = @import("opus");

pub fn main() void {
    std.debug.print("Opus version: {s}\n", .{std.mem.span(opus.getVersionString())});
}
