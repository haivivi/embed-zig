//! Mic Test Example - ESP Platform Entry Point

const std = @import("std");
const idf = @import("esp");
const app = @import("app");

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = idf.log.stdLogFn,
};

export fn app_main() void {
    app.run();
}
