//! WiFi Implementation for BK7258 — hal.wifi.Driver compatible

const armino = @import("../../armino/src/armino.zig");

/// Event types — structurally compatible with hal.wifi.WifiEvent
pub const DisconnectReason = enum { user_request, auth_failed, ap_not_found, connection_lost, unknown };
pub const FailReason = enum { timeout, auth_failed, ap_not_found, dhcp_failed, unknown };
pub const ScanDoneInfo = struct { success: bool };
pub const StaInfo = struct { mac: [6]u8, rssi: i8, aid: u16 };

/// AuthMode — structurally compatible with hal.wifi.AuthMode
pub const AuthMode = enum { open, wep, wpa_psk, wpa2_psk, wpa_wpa2_psk, wpa3_psk, wpa2_wpa3_psk, wpa2_enterprise, wpa3_enterprise };

/// AP info — structurally compatible with hal.wifi.ApInfo
pub const ApInfo = struct {
    ssid: [32]u8,
    ssid_len: u8,
    bssid: [6]u8,
    channel: u8,
    rssi: i8,
    auth_mode: AuthMode,
};

pub const WifiEvent = union(enum) {
    connected: void,
    disconnected: DisconnectReason,
    connection_failed: FailReason,
    scan_result: ApInfo,
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

    // Scan event-stream state
    /// Number of APs in current scan round
    scan_total: usize = 0,
    /// Index of the next AP to yield via pollEvent
    scan_cursor: usize = 0,
    /// Whether we are in the middle of yielding scan results
    scan_yielding: bool = false,
    /// Cached success flag from the scan_done event
    scan_success: bool = true,

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
        // On BK, events are polled from a C queue — calling pollEvent here
        // ensures connected state stays fresh (ESP uses ISR-driven callbacks)
        _ = @constCast(self).pollEvent();
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
    ///
    /// Scan event-stream: when armino reports scan_done, this function fetches
    /// all results from armino and yields them one-by-one as scan_result events,
    /// followed by a final scan_done.
    pub fn pollEvent(self: *Self) ?WifiEvent {
        // Priority 1: continue yielding scan results if a scan round is active
        if (self.scan_yielding) {
            if (self.scan_cursor < self.scan_total) {
                const ap = scan_buf[self.scan_cursor];
                self.scan_cursor += 1;
                return .{ .scan_result = ap };
            }
            // All results yielded — emit scan_done and reset
            self.scan_yielding = false;
            return .{ .scan_done = .{ .success = self.scan_success } };
        }

        // Priority 2: normal event polling from dispatcher
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
            .scan_done => |info| {
                // Intercept scan_done: fetch results from armino, start streaming
                self.scan_success = info.success;
                self.fetchScanResults();
                if (self.scan_total > 0) {
                    self.scan_yielding = true;
                    const ap = scan_buf[0];
                    self.scan_cursor = 1;
                    return .{ .scan_result = ap };
                }
                // No results — emit scan_done immediately
                return .{ .scan_done = .{ .success = info.success } };
            },
            else => {},
        }
        return event;
    }

    // ==========================================================================
    // Scanning — event-stream model
    // ==========================================================================

    /// Internal scan result buffer (populated from armino on scan_done)
    var scan_buf: [32]ApInfo = undefined;

    /// Start WiFi scan (non-blocking, results via scan_result events)
    pub fn scanStart(self: *Self, _: anytype) !void {
        // Reset any in-progress scan yield state
        self.scan_yielding = false;
        self.scan_cursor = 0;
        self.scan_total = 0;
        armino.wifi.scanStart() catch return error.ScanFailed;
    }

    /// Convert armino security code to AuthMode
    fn securityToAuthMode(sec: u8) AuthMode {
        return switch (sec) {
            0 => .open, // WIFI_SECURITY_NONE
            1 => .wep, // WIFI_SECURITY_WEP
            2, 3, 4 => .wpa_psk, // WIFI_SECURITY_WPA_*
            5, 6, 7 => .wpa2_psk, // WIFI_SECURITY_WPA2_*
            8 => .wpa3_psk, // WIFI_SECURITY_WPA3_SAE
            9 => .wpa2_wpa3_psk, // WIFI_SECURITY_WPA3_WPA2_MIXED
            10 => .wpa2_enterprise, // WIFI_SECURITY_EAP
            else => .open,
        };
    }

    /// Fetch scan results from armino and populate scan_buf.
    fn fetchScanResults(self: *Self) void {
        const raw = armino.wifi.scanGetResults();
        const n = @min(raw.len, scan_buf.len);
        for (raw[0..n], 0..) |ap, i| {
            const ssid_full = ap.getSsid();
            const ssid_len: u8 = @intCast(@min(ssid_full.len, 32));
            var ssid32: [32]u8 = @splat(0);
            @memcpy(ssid32[0..ssid_len], ssid_full[0..ssid_len]);
            scan_buf[i] = .{
                .ssid = ssid32,
                .ssid_len = ssid_len,
                .bssid = ap.bssid,
                .channel = ap.channel,
                .rssi = ap.rssi,
                .auth_mode = securityToAuthMode(ap.security),
            };
        }
        self.scan_total = n;
        self.scan_cursor = 0;
    }
};

pub const wifi_spec = struct {
    pub const Driver = WifiDriver;
    pub const meta = .{ .id = "wifi.sta" };
};
