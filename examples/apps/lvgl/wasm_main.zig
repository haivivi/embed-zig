//! WASM entry point for H106 UI prototype

const websim = @import("websim");
const app = @import("app.zig");

pub const init = app.init;
pub const step = app.step;

pub const board_config_json = websim.boards.h106.board_config_json;

comptime {
    websim.wasm.exportAll(@This());
}
