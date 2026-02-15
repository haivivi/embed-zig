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
    /// Track rapid disconnects to detect connection_failed (armino has no such event)
    disconnect_count: u8 = 0,
    last_disconnect_ms: u64 = 0,
    connecting: bool = false,

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
        self.connecting = true;
        self.disconnect_count = 0;
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
        self.connecting = false;
        self.disconnect_count = 0;
        armino.wifi.disconnect() catch {};
    }

    pub fn isConnected(self: *const Self) bool {
        return self.connected;
    }

    pub fn getIpAddress(self: *const Self) ?[4]u8 {
        if (self.connected) {
            const ip = armino.wifi.getIpAddress();
            return .{
                @truncate(ip & 0xFF),
                @truncate((ip >> 8) & 0xFF),
                @truncate((ip >> 16) & 0xFF),
                @truncate((ip >> 24) & 0xFF),
            };
        }
        return null;
    }

    /// Poll events via shared dispatcher (avoids dual-poll from same C queue).
    /// Detects connection_failed from rapid disconnects (armino quirk).
    pub fn pollEvent(self: *Self) ?WifiEvent {
        const event = @import("event_dispatch.zig").popWifi() orelse return null;
        switch (event) {
            .connected => {
                self.connected = true;
                self.connecting = false;
                self.disconnect_count = 0;
            },
            .disconnected => {
                self.connected = false;
                // If we're in connecting state and get rapid disconnects,
                // it means auth failed (armino doesn't have connection_failed event)
                if (self.connecting) {
                    const now = armino.time.nowMs();
                    if (now - self.last_disconnect_ms < 10000) {
                        self.disconnect_count += 1;
                    } else {
                        self.disconnect_count = 1;
                    }
                    self.last_disconnect_ms = now;

                    // 3+ rapid disconnects while connecting = auth failed
                    if (self.disconnect_count >= 3) {
                        self.connecting = false;
                        self.disconnect_count = 0;
                        return .{ .connection_failed = .auth_failed };
                    }
                }
            },
            else => {},
        }
        return event;
    }

    /// Start WiFi scan (non-blocking, results via scan_done event)
    pub fn scanStart(_: *Self, _: anytype) !void {
        armino.wifi.scanStart() catch return error.ScanFailed;
    }

    /// Get scan results (call after scan_done event)
    /// Returns HAL-compatible ApInfo by converting from armino's ScanAp format
    pub fn scanGetResults(_: *Self) []const ApInfo {
        const raw = armino.wifi.scanGetResults();
        for (raw, 0..) |ap, i| {
            const ssid_full = ap.getSsid();
            const ssid_len: u8 = @intCast(@min(ssid_full.len, 32));
            var ssid32: [32]u8 = .{0} ** 32;
            @memcpy(ssid32[0..ssid_len], ssid_full[0..ssid_len]);
            scan_results_hal[i] = .{
                .ssid = ssid32,
                .ssid_len = ssid_len,
                .bssid = ap.bssid,
                .channel = ap.channel,
                .rssi = ap.rssi,
                .auth_mode = securityToAuthMode(ap.security),
            };
        }
        return scan_results_hal[0..raw.len];
    }

    const wifi_hal = @import("hal").wifi;
    const ApInfo = wifi_hal.ApInfo;
    const AuthMode = wifi_hal.AuthMode;

    var scan_results_hal: [32]ApInfo = undefined;

    fn securityToAuthMode(sec: u8) AuthMode {
        return switch (sec) {
            0 => .open,       // WIFI_SECURITY_NONE
            1 => .wep,        // WIFI_SECURITY_WEP
            2, 3, 4 => .wpa_psk,   // WIFI_SECURITY_WPA_*
            5, 6, 7 => .wpa2_psk,  // WIFI_SECURITY_WPA2_*
            8 => .wpa3_psk,        // WIFI_SECURITY_WPA3_SAE
            9 => .wpa2_wpa3_psk,   // WIFI_SECURITY_WPA3_WPA2_MIXED
            10 => .wpa2_enterprise, // WIFI_SECURITY_EAP
            else => .open,
        };
    }
};

pub const wifi_spec = struct {
    pub const Driver = WifiDriver;
    pub const meta = .{ .id = "wifi.sta" };
};
