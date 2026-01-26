//! NVS Storage Example - ESP32 Entry Point
//!
//! Minimal entry point that delegates to the platform-independent app.

const std = @import("std");
const idf = @import("esp");
const app = @import("app");

pub const std_options: std.Options = .{
    .logFn = idf.log.stdLogFn,
};

export fn app_main() void {
    app.run();
}
