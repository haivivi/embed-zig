//! WASM entry point for LVGL app on WebSim
//!
//! Thin glue: adapts app.init/step to WASM cooperative exports.

const websim = @import("websim");
const app = @import("app.zig");

pub const init = app.init;
pub const step = app.step;

comptime {
    websim.wasm.exportAll(@This());
}
