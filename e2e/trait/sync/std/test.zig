//! std platform entry for e2e trait/sync

const std = @import("std");
const e2e_sync = @import("e2e_sync");
const Board = @import("board.zig");

test "e2e: trait/sync" {
    try e2e_sync.run(Board);
}
