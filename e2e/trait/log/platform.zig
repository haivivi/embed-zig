//! Platform Configuration — e2e trait/log
//!
//! This file is IDENTICAL for all platforms. The build system selects the board.

const board = @import("board");

pub const log = board.log;
