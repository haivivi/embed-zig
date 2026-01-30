//! WiFi Implementation for ESP32
//!
//! Implements hal.wifi Driver interface using idf.wifi.
//!
//! Usage:
//!   const impl = @import("impl");
//!   const hal = @import("hal");
//!
//!   const wifi_spec = struct {
//!       pub const Driver = impl.WifiDriver;
//!       pub const meta = .{ .id = "wifi.main" };
//!   };
//!   const Wifi = hal.wifi.from(wifi_spec);

const idf = @import("idf");

/// WiFi Driver that implements hal.wifi.Driver interface
pub const WifiDriver = struct {
    const Self = @This();

    wifi: idf.Wifi,

    /// Initialize WiFi driver
    pub fn init() !Self {
        const wifi = try idf.Wifi.init();
        return .{ .wifi = wifi };
    }

    /// Deinitialize WiFi driver
    pub fn deinit(self: *Self) void {
        self.wifi.deinit();
    }

    /// Connect to WiFi network (required by hal.wifi)
    pub fn connect(self: *Self, ssid: []const u8, password: []const u8) !void {
        try self.wifi.connect(ssid, password);
    }

    /// Disconnect from WiFi (required by hal.wifi)
    pub fn disconnect(self: *Self) void {
        self.wifi.disconnect();
    }

    /// Check if connected (required by hal.wifi)
    pub fn isConnected(self: *const Self) bool {
        return self.wifi.isConnected();
    }

    /// Get IP address (required by hal.wifi)
    pub fn getIpAddress(self: *const Self) ?[4]u8 {
        return self.wifi.getIpAddress();
    }

    /// Get RSSI (optional for hal.wifi)
    pub fn getRssi(self: *const Self) ?i8 {
        return self.wifi.getRssi();
    }

    /// Get MAC address (optional for hal.wifi)
    pub fn getMac(self: *const Self) ?[6]u8 {
        return self.wifi.getMac();
    }
};
