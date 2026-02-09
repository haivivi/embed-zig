//! BK7258 WiFi STA Binding
//!
//! Wraps Armino WiFi STA + event registration via C helpers.

// C helpers (bk_zig_wifi_helper.c)
extern fn bk_zig_wifi_init() c_int;
extern fn bk_zig_wifi_register_events(
    wifi_cb: *const fn (c_int, ?*anyopaque, c_int) callconv(.C) void,
    netif_cb: *const fn (c_int, [*:0]const u8) callconv(.C) void,
) c_int;
extern fn bk_zig_wifi_sta_connect(ssid: [*:0]const u8, password: [*:0]const u8) c_int;
extern fn bk_zig_wifi_sta_disconnect() c_int;
extern fn bk_zig_netif_get_ip4(ip_out: *[4]u8, dns_out: *[4]u8) c_int;

// ============================================================================
// WiFi Event IDs (from wifi_types.h)
// ============================================================================

pub const EVENT_SCAN_DONE: c_int = 0;
pub const EVENT_STA_CONNECTED: c_int = 2;
pub const EVENT_STA_DISCONNECTED: c_int = 4;

// Netif Event IDs (from netif_types.h)
pub const EVENT_NETIF_GOT_IP4: c_int = 0;
pub const EVENT_NETIF_DHCP_TIMEOUT: c_int = 1;

// ============================================================================
// WiFi Event Types
// ============================================================================

pub const WifiEvent = union(enum) {
    connected,
    disconnected: u16, // reason code
    scan_done: u32, // count
    got_ip: struct { ip: [4]u8, dns: [4]u8 },
    dhcp_timeout,
};

// ============================================================================
// Event Queue (simple ring buffer)
// ============================================================================

const MAX_EVENTS = 16;

var event_queue: [MAX_EVENTS]WifiEvent = undefined;
var event_head: usize = 0;
var event_tail: usize = 0;

fn pushEvent(ev: WifiEvent) void {
    event_queue[event_tail] = ev;
    event_tail = (event_tail + 1) % MAX_EVENTS;
    // If full, drop oldest
    if (event_tail == event_head) {
        event_head = (event_head + 1) % MAX_EVENTS;
    }
}

pub fn popEvent() ?WifiEvent {
    if (event_head == event_tail) return null;
    const ev = event_queue[event_head];
    event_head = (event_head + 1) % MAX_EVENTS;
    return ev;
}

// ============================================================================
// C Callbacks → Zig Event Queue
// ============================================================================

fn wifiEventCallback(event_id: c_int, _: ?*anyopaque, _: c_int) callconv(.C) void {
    switch (event_id) {
        EVENT_STA_CONNECTED => pushEvent(.connected),
        EVENT_STA_DISCONNECTED => pushEvent(.{ .disconnected = 0 }),
        EVENT_SCAN_DONE => pushEvent(.{ .scan_done = 0 }),
        else => {},
    }
}

fn netifEventCallback(event_id: c_int, ip_str: [*:0]const u8) callconv(.C) void {
    switch (event_id) {
        EVENT_NETIF_GOT_IP4 => {
            var ip: [4]u8 = .{ 0, 0, 0, 0 };
            var dns: [4]u8 = .{ 0, 0, 0, 0 };
            _ = bk_zig_netif_get_ip4(&ip, &dns);
            _ = ip_str; // IP string available but we use binary from netif_get_ip4
            pushEvent(.{ .got_ip = .{ .ip = ip, .dns = dns } });
        },
        EVENT_NETIF_DHCP_TIMEOUT => pushEvent(.dhcp_timeout),
        else => {},
    }
}

// ============================================================================
// Public API
// ============================================================================

pub fn init() !void {
    if (bk_zig_wifi_init() != 0) return error.WifiInitFailed;
    if (bk_zig_wifi_register_events(&wifiEventCallback, &netifEventCallback) != 0)
        return error.EventRegisterFailed;
}

pub fn connect(ssid: [*:0]const u8, password: [*:0]const u8) !void {
    if (bk_zig_wifi_sta_connect(ssid, password) != 0)
        return error.WifiConnectFailed;
}

pub fn disconnect() !void {
    if (bk_zig_wifi_sta_disconnect() != 0)
        return error.WifiDisconnectFailed;
}

pub fn getIp4() !struct { ip: [4]u8, dns: [4]u8 } {
    var ip: [4]u8 = .{ 0, 0, 0, 0 };
    var dns: [4]u8 = .{ 0, 0, 0, 0 };
    if (bk_zig_netif_get_ip4(&ip, &dns) != 0) return error.NetifGetIpFailed;
    return .{ .ip = ip, .dns = dns };
}
