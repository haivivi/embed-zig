//! Tetris — Native WebSim entry point
//!
//! Single binary with embedded webview window.
//! Same game logic as WASM version, but runs natively.

const websim = @import("websim");
const app = @import("app.zig");

pub const init = app.init;
pub const step = app.step;
pub const board_config_json = websim.boards.h106.board_config_json;

const html = @embedFile("native_shell.html");

pub fn main() !void {
    websim.native.run(@This(), html);
}
