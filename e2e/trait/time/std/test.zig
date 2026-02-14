//! std platform entry for e2e trait/time

const std = @import("std");
const e2e_time = @import("e2e_time");
const Board = @import("board.zig");

test "e2e: trait/time" {
    try e2e_time.run(Board);
}
