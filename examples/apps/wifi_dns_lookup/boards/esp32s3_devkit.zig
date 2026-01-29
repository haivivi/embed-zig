//! ESP32-S3 DevKit Board Implementation for WiFi DNS Lookup
//!
//! Hardware:
//! - WiFi Station mode
//! - BSD Sockets via LWIP

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const idf = esp.idf;
const hw_params = esp.boards.esp32s3_devkit;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = hw_params.name;
    pub const serial_port = hw_params.serial_port;
};

// ============================================================================
// Socket Implementation (from ESP IDF)
// ============================================================================

pub const socket = idf.socket.Socket;

// ============================================================================
// RTC Driver
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return idf.time.nowMs();
    }

    pub fn nowMs(_: *Self) ?i64 {
        return null;
    }
};

// ============================================================================
// WiFi Driver (wraps idf.Wifi for HAL compatibility)
// ============================================================================

pub const WifiDriver = struct {
    const Self = @This();

    wifi: ?idf.Wifi = null,
    connected: bool = false,
    ip_address: ?hal.wifi.IpAddress = null,

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        if (self.wifi) |*w| {
            w.disconnect();
        }
        self.wifi = null;
        self.connected = false;
        self.ip_address = null;
    }

    pub fn connect(self: *Self, ssid: []const u8, password: []const u8) !void {
        // Initialize WiFi if not already done
        if (self.wifi == null) {
            self.wifi = idf.Wifi.init() catch |err| {
                std.log.err("WiFi init failed: {}", .{err});
                return error.InitFailed;
            };
        }

        // Connect with sentinel-terminated strings
        var ssid_buf: [33:0]u8 = undefined;
        var pass_buf: [65:0]u8 = undefined;

        const ssid_len = @min(ssid.len, 32);
        const pass_len = @min(password.len, 64);

        @memcpy(ssid_buf[0..ssid_len], ssid[0..ssid_len]);
        ssid_buf[ssid_len] = 0;

        @memcpy(pass_buf[0..pass_len], password[0..pass_len]);
        pass_buf[pass_len] = 0;

        self.wifi.?.connect(.{
            .ssid = ssid_buf[0..ssid_len :0],
            .password = pass_buf[0..pass_len :0],
            .timeout_ms = 30000,
        }) catch |err| {
            std.log.err("WiFi connect failed: {}", .{err});
            return error.ConnectFailed;
        };

        self.connected = true;
        self.ip_address = self.wifi.?.getIpAddress();
    }

    pub fn disconnect(self: *Self) void {
        if (self.wifi) |*w| {
            w.disconnect();
        }
        self.connected = false;
        self.ip_address = null;
    }

    pub fn isConnected(self: *const Self) bool {
        return self.connected;
    }

    pub fn getIpAddress(self: *const Self) ?hal.wifi.IpAddress {
        return self.ip_address;
    }

    pub fn getRssi(self: *const Self) ?i8 {
        if (self.wifi) |*w| {
            return w.getRssi();
        }
        return null;
    }
};

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const wifi_spec = struct {
    pub const Driver = WifiDriver;
    pub const meta = .{ .id = "wifi.main" };
};

// ============================================================================
// Platform Primitives
// ============================================================================

pub const log = std.log.scoped(.app);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.time.sleepMs(ms);
    }

    pub fn getTimeMs() u64 {
        return idf.time.nowMs();
    }
};

pub fn isRunning() bool {
    return true; // ESP: always running
}
