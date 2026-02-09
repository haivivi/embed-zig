//! Event Dispatcher for BK7258
//!
//! Single point that polls armino.wifi.popEvent() and dispatches to
//! separate WiFi and Net event buffers. Avoids the dual-poll problem
//! where two drivers consume from the same C queue.

const armino = @import("../../armino/src/armino.zig");
const wifi_impl = @import("wifi.zig");
const net_impl = @import("net.zig");

var pending_wifi: ?wifi_impl.WifiEvent = null;
var pending_net: ?net_impl.NetEvent = null;

/// Poll the armino C-side event queue once and dispatch
fn dispatch() void {
    const event = armino.wifi.popEvent() orelse return;
    switch (event) {
        .connected => {
            pending_wifi = .{ .connected = {} };
        },
        .disconnected => {
            pending_wifi = .{ .disconnected = .unknown };
        },
        .scan_done => {
            pending_wifi = .{ .scan_done = .{ .count = 0, .success = true } };
        },
        .got_ip => |ip_info| {
            pending_net = .{
                .dhcp_bound = .{
                    .ip = ip_info.ip,
                    .netmask = .{ 255, 255, 255, 0 },
                    .gateway = .{ 0, 0, 0, 0 },
                    .dns_main = ip_info.dns,
                    .dns_backup = .{ 0, 0, 0, 0 },
                    .lease_time = 0,
                },
            };
        },
        .dhcp_timeout => {
            pending_net = .{ .ip_lost = .{} };
        },
    }
}

/// Pop a pending WiFi event (called by WifiDriver.pollEvent)
pub fn popWifi() ?wifi_impl.WifiEvent {
    dispatch();
    const evt = pending_wifi;
    pending_wifi = null;
    return evt;
}

/// Pop a pending Net event (called by NetDriver.pollEvent)
pub fn popNet() ?net_impl.NetEvent {
    dispatch();
    const evt = pending_net;
    pending_net = null;
    return evt;
}
