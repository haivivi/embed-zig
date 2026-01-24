//! WiFi station mode connection
//! Uses extern functions to avoid complex C struct translation issues

const std = @import("std");
const rtos = @import("rtos.zig");

const c = @cImport({
    @cInclude("esp_err.h");
    @cInclude("nvs_flash.h");
});

pub const WifiError = error{
    NvsInitFailed,
    InitFailed,
    ConfigFailed,
    StartFailed,
    ConnectFailed,
    Timeout,
};

pub const WifiConfig = struct {
    ssid: []const u8,
    password: []const u8,
    timeout_ms: u32 = 30000,
};

pub const WifiState = enum(u8) {
    disconnected = 0,
    connecting = 1,
    connected = 2,
    got_ip = 3,
};

// External C helper functions (defined in main.c)
extern fn wifi_helper_init() c_int;
extern fn wifi_helper_connect(ssid: [*:0]const u8, password: [*:0]const u8) c_int;
extern fn wifi_helper_get_state() u8;
extern fn wifi_helper_get_ip(ip_out: *[4]u8) void;
extern fn wifi_helper_disconnect() void;

pub const Wifi = struct {
    const Self = @This();

    pub fn init() WifiError!Self {
        // Initialize NVS
        var ret = c.nvs_flash_init();
        if (ret == c.ESP_ERR_NVS_NO_FREE_PAGES or ret == c.ESP_ERR_NVS_NEW_VERSION_FOUND) {
            _ = c.nvs_flash_erase();
            ret = c.nvs_flash_init();
        }
        if (ret != c.ESP_OK) return error.NvsInitFailed;

        // Initialize WiFi via helper
        if (wifi_helper_init() != c.ESP_OK) return error.InitFailed;

        return .{};
    }

    pub fn connect(self: *Self, config: WifiConfig) WifiError!void {
        _ = self;

        // Copy SSID and password to null-terminated buffers
        var ssid_buf: [33]u8 = [_]u8{0} ** 33;
        var pass_buf: [65]u8 = [_]u8{0} ** 65;

        const ssid_len = @min(config.ssid.len, 32);
        const pass_len = @min(config.password.len, 64);

        @memcpy(ssid_buf[0..ssid_len], config.ssid[0..ssid_len]);
        @memcpy(pass_buf[0..pass_len], config.password[0..pass_len]);

        if (wifi_helper_connect(@ptrCast(&ssid_buf), @ptrCast(&pass_buf)) != c.ESP_OK) {
            return error.ConnectFailed;
        }

        // Wait for connection
        const timeout_ticks = config.timeout_ms / rtos.portTICK_PERIOD_MS;
        var elapsed: u32 = 0;

        while (wifi_helper_get_state() != @intFromEnum(WifiState.got_ip)) {
            if (config.timeout_ms > 0 and elapsed >= timeout_ticks) {
                return error.Timeout;
            }
            rtos.delayMs(100);
            elapsed += 100 / rtos.portTICK_PERIOD_MS;
        }
    }

    pub fn getIpAddress(self: *Self) [4]u8 {
        _ = self;
        var ip: [4]u8 = undefined;
        wifi_helper_get_ip(&ip);
        return ip;
    }

    pub fn getState(self: *Self) WifiState {
        _ = self;
        return @enumFromInt(wifi_helper_get_state());
    }

    pub fn disconnect(self: *Self) void {
        _ = self;
        wifi_helper_disconnect();
    }
};
