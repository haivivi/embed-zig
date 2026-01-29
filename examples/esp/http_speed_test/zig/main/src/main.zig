//! ESP Platform Entry Point - HTTP Speed Test

const std = @import("std");
const idf = @import("esp");
const app = @import("app");

const c = @cImport({
    @cInclude("sdkconfig.h");
});

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = idf.log.stdLogFn,
};

export fn app_main() void {
    // Read config from Kconfig
    const ssid: [:0]const u8 = std.mem.span(@as([*:0]const u8, c.CONFIG_WIFI_SSID));
    const password: [:0]const u8 = std.mem.span(@as([*:0]const u8, c.CONFIG_WIFI_PASSWORD));
    const server_ip: [:0]const u8 = std.mem.span(@as([*:0]const u8, c.CONFIG_TEST_SERVER_IP));
    const server_port: u16 = c.CONFIG_TEST_SERVER_PORT;

    app.runWithConfig(ssid, password, server_ip, server_port);
}
