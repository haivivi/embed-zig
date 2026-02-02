//! ESP-IDF WiFi Low-level API
//!
//! Thin wrapper over ESP-IDF WiFi functions.
//! Does NOT handle netif creation or event loop - use idf/net and idf/event.
//!
//! ## Dependency Order
//!
//! 1. `idf.event.init()` - Create event loop
//! 2. `idf.net.netif.init()` - Initialize netif subsystem
//! 3. `idf.net.netif.createWifiSta()` or `createWifiAp()` - Create netif
//! 4. `wifi.init()` - Initialize WiFi driver
//! 5. `wifi.setMode()` - Set mode (STA/AP/APSTA)
//! 6. `wifi.setStaConfig()` or `wifi.setApConfig()` - Configure
//! 7. `wifi.start()` - Start WiFi
//!
//! ## Usage Example (STA mode)
//!
//! ```zig
//! const idf = @import("idf");
//!
//! // Initialize dependencies
//! try idf.event.init();
//! try idf.net.netif.init();
//! try idf.net.netif.createWifiSta();
//!
//! // Initialize and configure WiFi
//! try idf.wifi.init();
//! try idf.wifi.setMode(.sta);
//! try idf.wifi.setStaConfig("MySSID", "MyPassword");
//! try idf.wifi.start();
//!
//! // Connect (blocking)
//! try idf.wifi.connect(.{ .timeout_ms = 30000 });
//! ```

const std = @import("std");

// ============================================================================
// C Helper Functions
// ============================================================================

extern fn wifi_helper_init() c_int;
extern fn wifi_helper_deinit() void;
extern fn wifi_helper_set_mode(mode: c_int) c_int;
extern fn wifi_helper_set_sta_config(ssid: [*:0]const u8, password: [*:0]const u8) c_int;
extern fn wifi_helper_set_ap_config(ssid: [*:0]const u8, password: [*:0]const u8, channel: c_int, max_conn: c_int) c_int;
extern fn wifi_helper_start() c_int;
extern fn wifi_helper_stop() void;
extern fn wifi_helper_connect(timeout_ms: u32, max_retry: c_int) c_int;
extern fn wifi_helper_disconnect() void;
extern fn wifi_helper_get_sta_ip() u32;
extern fn wifi_helper_get_rssi() i8;
extern fn wifi_helper_get_ap_station_count() c_int;
extern fn wifi_helper_get_ap_stations(mac_list: [*]u8, max_count: c_int) c_int;

// Legacy API
extern fn wifi_helper_legacy_init() c_int;
extern fn wifi_helper_legacy_connect(ssid: [*:0]const u8, password: [*:0]const u8, timeout_ms: u32) c_int;
extern fn wifi_helper_get_ip() u32;

// ============================================================================
// Types
// ============================================================================

pub const Error = error{
    InitFailed,
    ConfigFailed,
    StartFailed,
    ConnectFailed,
    Timeout,
    InvalidMode,
};

/// WiFi operating mode
pub const Mode = enum(c_int) {
    sta = 1,
    ap = 2,
    apsta = 3,
};

/// STA configuration
pub const StaConfig = struct {
    ssid: [:0]const u8,
    password: [:0]const u8,
};

/// AP configuration
pub const ApConfig = struct {
    ssid: [:0]const u8,
    password: [:0]const u8 = "",
    channel: u8 = 1,
    max_connections: u8 = 4,
};

/// Connect options
pub const ConnectOptions = struct {
    timeout_ms: u32 = 30000,
    max_retry: u8 = 5,
};

/// Station info (for AP mode)
pub const StationInfo = struct {
    mac: [6]u8,
};

// ============================================================================
// Low-level API
// ============================================================================

/// Initialize WiFi driver
/// Requires: event loop and netif must be initialized first
pub fn init() Error!void {
    if (wifi_helper_init() != 0) {
        return error.InitFailed;
    }
}

/// Deinitialize WiFi driver
pub fn deinit() void {
    wifi_helper_deinit();
}

/// Set WiFi operating mode
pub fn setMode(mode: Mode) Error!void {
    if (wifi_helper_set_mode(@intFromEnum(mode)) != 0) {
        return error.ConfigFailed;
    }
}

/// Configure STA mode
pub fn setStaConfig(ssid: [:0]const u8, password: [:0]const u8) Error!void {
    if (wifi_helper_set_sta_config(ssid.ptr, password.ptr) != 0) {
        return error.ConfigFailed;
    }
}

/// Configure AP mode
pub fn setApConfig(config: ApConfig) Error!void {
    if (wifi_helper_set_ap_config(
        config.ssid.ptr,
        config.password.ptr,
        config.channel,
        config.max_connections,
    ) != 0) {
        return error.ConfigFailed;
    }
}

/// Start WiFi (applies configuration)
pub fn start() Error!void {
    if (wifi_helper_start() != 0) {
        return error.StartFailed;
    }
}

/// Stop WiFi
pub fn stop() void {
    wifi_helper_stop();
}

/// Connect to AP (STA mode, blocking)
pub fn connect(options: ConnectOptions) Error!void {
    const ret = wifi_helper_connect(options.timeout_ms, options.max_retry);
    if (ret == 0) {
        return;
    } else if (ret == -2) {
        return error.Timeout;
    } else {
        return error.ConnectFailed;
    }
}

/// Disconnect from AP (STA mode)
pub fn disconnect() void {
    wifi_helper_disconnect();
}

/// Get STA IP address
pub fn getStaIp() [4]u8 {
    const ip = wifi_helper_get_sta_ip();
    return .{
        @truncate(ip & 0xFF),
        @truncate((ip >> 8) & 0xFF),
        @truncate((ip >> 16) & 0xFF),
        @truncate((ip >> 24) & 0xFF),
    };
}

/// Get current RSSI (STA mode)
pub fn getRssi() i8 {
    return wifi_helper_get_rssi();
}

/// Get number of connected stations (AP mode)
pub fn getApStationCount() usize {
    const count = wifi_helper_get_ap_station_count();
    return if (count > 0) @intCast(count) else 0;
}

/// Get connected station MACs (AP mode)
/// Returns slice of actual stations found
pub fn getApStations(buffer: []StationInfo) []StationInfo {
    if (buffer.len == 0) return buffer[0..0];

    // Temporary buffer for raw MAC data
    var mac_buf: [10 * 6]u8 = undefined;
    const max_count: c_int = @intCast(@min(buffer.len, 10));

    const count = wifi_helper_get_ap_stations(&mac_buf, max_count);
    if (count <= 0) return buffer[0..0];

    const result_count: usize = @intCast(count);
    for (0..result_count) |i| {
        @memcpy(&buffer[i].mac, mac_buf[i * 6 ..][0..6]);
    }

    return buffer[0..result_count];
}

// ============================================================================
// Legacy High-level API (for backward compatibility)
// ============================================================================

/// Legacy WiFi struct (combines init + connect)
/// Prefer using the low-level API for new code
pub const Wifi = struct {
    const Self = @This();

    pub fn init() Error!Self {
        // Legacy init expects netif and event loop to be ready
        // The new impl/wifi.StaDriver handles this properly
        if (wifi_helper_legacy_init() != 0) {
            return error.InitFailed;
        }
        return .{};
    }

    pub fn connect(self: *Self, config: LegacyConnectConfig) Error!void {
        _ = self;
        const ret = wifi_helper_legacy_connect(
            config.ssid.ptr,
            config.password.ptr,
            config.timeout_ms,
        );
        if (ret == 0) {
            return;
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

    pub fn getRssi(self: *const Self) i8 {
        _ = self;
        return wifi_helper_get_rssi();
    }
};

pub const LegacyConnectConfig = struct {
    ssid: [:0]const u8,
    password: [:0]const u8,
    timeout_ms: u32 = 30000,
};

/// Convenience: get RSSI without instance
pub fn legacyGetRssi() i8 {
    return wifi_helper_get_rssi();
}
