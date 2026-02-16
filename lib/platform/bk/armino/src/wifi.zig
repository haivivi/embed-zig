//! BK7258 WiFi STA Binding — C-side event queue

// C helpers
extern fn bk_zig_wifi_init() c_int;
extern fn bk_zig_wifi_register_events() c_int;
extern fn bk_zig_wifi_sta_connect(ssid: [*:0]const u8, password: [*:0]const u8) c_int;
extern fn bk_zig_wifi_sta_disconnect() c_int;
extern fn bk_zig_wifi_poll_event(out_type: *c_int, out_ip: *[4]u8, out_dns: *[4]u8) c_int;
extern fn bk_zig_wifi_scan_start() c_int;
extern fn bk_zig_wifi_scan_get_results(out_count: *c_int) c_int;
extern fn bk_zig_wifi_scan_get_ap_flat(index: c_int, out: *ScanApFlat) c_int;
extern fn bk_zig_netif_get_ip4(ip_out: *[4]u8, dns_out: *[4]u8) c_int;

/// Flat struct matching C bk_zig_scan_ap_flat_t (packed, no alignment gaps)
const ScanApFlat = extern struct {
    ssid: [33]u8,      // 0-32
    bssid: [6]u8,      // 33-38
    rssi: i8,          // 39
    channel: u8,       // 40
    security: u8,      // 41
    _pad: [2]u8,       // 42-43
};

const EVT_CONNECTED: c_int = 1;
const EVT_DISCONNECTED: c_int = 2;
const EVT_GOT_IP: c_int = 3;
const EVT_DHCP_TIMEOUT: c_int = 4;
const EVT_SCAN_DONE: c_int = 5;

pub const WifiEvent = union(enum) {
    connected,
    disconnected,
    scan_done,
    got_ip: struct { ip: [4]u8, dns: [4]u8 },
    dhcp_timeout,
};

pub fn init() !void {
    if (bk_zig_wifi_init() != 0) return error.WifiInitFailed;
    if (bk_zig_wifi_register_events() != 0) return error.EventRegisterFailed;
}

pub fn connect(ssid: [*:0]const u8, password: [*:0]const u8) !void {
    if (bk_zig_wifi_sta_connect(ssid, password) != 0)
        return error.WifiConnectFailed;
}

pub fn disconnect() !void {
    if (bk_zig_wifi_sta_disconnect() != 0)
        return error.WifiDisconnectFailed;
}

/// Poll next event from C-side queue. Returns any event type.
/// Caller is responsible for handling/routing wifi vs net events.
pub fn popEvent() ?WifiEvent {
    var evt_type: c_int = 0;
    var ip: [4]u8 = .{ 0, 0, 0, 0 };
    var dns: [4]u8 = .{ 0, 0, 0, 0 };
    if (bk_zig_wifi_poll_event(&evt_type, &ip, &dns) == 0) return null;
    return switch (evt_type) {
        EVT_CONNECTED => .connected,
        EVT_DISCONNECTED => .disconnected,
        EVT_GOT_IP => .{ .got_ip = .{ .ip = ip, .dns = dns } },
        EVT_DHCP_TIMEOUT => .dhcp_timeout,
        EVT_SCAN_DONE => .scan_done,
        else => null,
    };
}

// ============================================================================
// Scan
// ============================================================================

pub const ScanAp = struct {
    ssid: [33]u8,
    bssid: [6]u8,
    rssi: i8,
    channel: u8,
    security: u8,

    pub fn getSsid(self: *const ScanAp) []const u8 {
        const len = @import("std").mem.indexOfScalar(u8, &self.ssid, 0) orelse self.ssid.len;
        return self.ssid[0..len];
    }
};

pub fn getIpAddress() u32 {
    var ip: [4]u8 = .{ 0, 0, 0, 0 };
    var dns: [4]u8 = .{ 0, 0, 0, 0 };
    _ = bk_zig_netif_get_ip4(&ip, &dns);
    return @as(u32, ip[0]) | (@as(u32, ip[1]) << 8) | (@as(u32, ip[2]) << 16) | (@as(u32, ip[3]) << 24);
}

pub fn scanStart() !void {
    if (bk_zig_wifi_scan_start() != 0) return error.ScanFailed;
}

var scan_results: [32]ScanAp = undefined;
var scan_count: usize = 0;

pub fn scanGetResults() []const ScanAp {
    var count: c_int = 0;
    if (bk_zig_wifi_scan_get_results(&count) != 0) return &[0]ScanAp{};
    scan_count = @intCast(@max(0, @min(count, 32)));

    for (0..scan_count) |i| {
        var flat: ScanApFlat = undefined;
        if (bk_zig_wifi_scan_get_ap_flat(@intCast(i), &flat) == 0) {
            scan_results[i] = .{
                .ssid = flat.ssid,
                .bssid = flat.bssid,
                .rssi = flat.rssi,
                .channel = flat.channel,
                .security = flat.security,
            };
        }
    }

    return scan_results[0..scan_count];
}
