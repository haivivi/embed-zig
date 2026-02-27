//! Platform Configuration — e2e selector
//!
//! Imports the "board" module injected by Bazel deps.

const board = @import("board");

pub const log = board.log;
pub const time = board.time;
pub const channel = board.channel;
pub const selector = board.selector;
