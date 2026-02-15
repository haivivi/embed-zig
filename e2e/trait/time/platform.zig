//! Platform Configuration — e2e trait/time
//!
//! Imports the "board" module which is injected by Bazel deps.
//! std build: deps include std_board (module_name = "board")
//! ESP build: deps include esp_board (module_name = "board")
//!
//! This file is IDENTICAL for all platforms. The build system selects the board.

const board = @import("board");

pub const log = board.log;
pub const time = board.time;
