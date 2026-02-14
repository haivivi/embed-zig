//! Platform Configuration — e2e trait/sync
//!
//! This file is IDENTICAL for all platforms. The build system selects the board.

const board = @import("board");

pub const log = board.log;
pub const time = board.time;
pub const runtime = board.runtime;
