//! std platform entry for e2e trait/log

const std = @import("std");
const e2e_log = @import("e2e_log");
const Board = @import("board.zig");

test "e2e: trait/log" {
    try e2e_log.run(Board);
}
