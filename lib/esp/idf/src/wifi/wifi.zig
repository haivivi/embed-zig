//! WiFi station mode - thin wrapper over C helpers
//!
//! Complex ESP-IDF types (wifi_config_t, wifi_init_config_t) are handled in
//! esp/src/wifi/helper.c which is bundled with this package.

const std = @import("std");

// ============================================================================
// C helper functions (from esp/src/wifi/helper.c)
// ============================================================================

extern fn wifi_helper_nvs_init() c_int;
extern fn wifi_helper_init() c_int;
extern fn wifi_helper_connect(ssid: [*:0]const u8, password: [*:0]const u8, timeout_ms: u32) c_int;
extern fn wifi_helper_get_ip() u32;
extern fn wifi_helper_disconnect() void;
extern fn wifi_helper_get_rssi() i8;

// ============================================================================
// Public API
// ============================================================================

pub const Error = error{
    NvsInitFailed,
    InitFailed,
    ConnectFailed,
    Timeout,
};

pub const ConnectConfig = struct {
    ssid: [:0]const u8,
    password: [:0]const u8,
    timeout_ms: u32 = 30000,
};

pub const Wifi = struct {
    const Self = @This();

    pub fn init() Error!Self {
        // Initialize NVS
        if (wifi_helper_nvs_init() != 0) {
            return error.NvsInitFailed;
        }

        // Initialize WiFi
        if (wifi_helper_init() != 0) {
            return error.InitFailed;
        }

        return .{};
    }

    pub fn connect(self: *Self, config: ConnectConfig) Error!void {
        _ = self;

        const ret = wifi_helper_connect(config.ssid.ptr, config.password.ptr, config.timeout_ms);

        if (ret == 0) {
            return; // ESP_OK
        } else if (ret == 0x107) { // ESP_ERR_TIMEOUT
            return error.Timeout;
        } else {
            return error.ConnectFailed;
        }
    }

    pub fn getIpAddress(self: *Self) [4]u8 {
        _ = self;
        const ip = wifi_helper_get_ip();
        return .{
            @truncate(ip & 0xFF),
            @truncate((ip >> 8) & 0xFF),
            @truncate((ip >> 16) & 0xFF),
            @truncate((ip >> 24) & 0xFF),
        };
    }

    pub fn disconnect(self: *Self) void {
        _ = self;
        wifi_helper_disconnect();
    }

    /// Get current WiFi signal strength (RSSI in dBm)
    pub fn getRssi(self: *Self) i8 {
        _ = self;
        return wifi_helper_get_rssi();
    }
};

/// Get WiFi RSSI without Wifi instance (convenience function)
pub fn getRssi() i8 {
    return wifi_helper_get_rssi();
}
