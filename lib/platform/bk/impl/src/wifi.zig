//! WiFi Implementation for BK7258 — hal.wifi.Driver compatible

const armino = @import("../../armino/src/armino.zig");

/// Event types — structurally compatible with hal.wifi.WifiEvent
pub const DisconnectReason = enum { user_request, auth_failed, ap_not_found, connection_lost, unknown };
pub const FailReason = enum { timeout, auth_failed, ap_not_found, dhcp_failed, unknown };
pub const ScanDoneInfo = struct { count: u16, success: bool };
pub const StaInfo = struct { mac: [6]u8, rssi: i8, aid: u16 };

pub const WifiEvent = union(enum) {
    connected: void,
    disconnected: DisconnectReason,
    connection_failed: FailReason,
    scan_done: ScanDoneInfo,
    rssi_low: i8,
    ap_sta_connected: StaInfo,
    ap_sta_disconnected: StaInfo,
};

/// WiFi STA Driver — hal.wifi.Driver compatible
pub const WifiDriver = struct {
    const Self = @This();

    initialized: bool = false,
    connected: bool = false,

    pub fn init() !Self {
        armino.wifi.init() catch return error.InitFailed;
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        self.initialized = false;
        self.connected = false;
    }

    /// Non-blocking connect
    pub fn connect(self: *Self, ssid: []const u8, password: []const u8) void {
        _ = self;
        var ssid_buf: [33:0]u8 = @splat(0);
        var pass_buf: [65:0]u8 = @splat(0);
        const sl = @min(ssid.len, 32);
        const pl = @min(password.len, 64);
        @memcpy(ssid_buf[0..sl], ssid[0..sl]);
        @memcpy(pass_buf[0..pl], password[0..pl]);
        armino.wifi.connect(&ssid_buf, &pass_buf) catch {};
    }

    pub fn disconnect(self: *Self) void {
        self.connected = false;
        armino.wifi.disconnect() catch {};
    }

    pub fn isConnected(self: *const Self) bool {
        return self.connected;
    }

    /// Poll events via shared dispatcher (avoids dual-poll from same C queue).
    pub fn pollEvent(self: *Self) ?WifiEvent {
        const event = @import("event_dispatch.zig").popWifi() orelse return null;
        switch (event) {
            .connected => self.connected = true,
            .disconnected => self.connected = false,
            else => {},
        }
        return event;
    }
};

pub const wifi_spec = struct {
    pub const Driver = WifiDriver;
    pub const meta = .{ .id = "wifi.sta" };
};
