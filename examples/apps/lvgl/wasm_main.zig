//! WASM entry point for H106 UI prototype

const websim = @import("websim");
const app = @import("app.zig");

pub const init = app.init;
pub const step = app.step;

comptime {
    websim.wasm.exportAll(@This());
}
