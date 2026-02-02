//! ESP-IDF Network Interface Bindings
//!
//! Wraps esp_netif C APIs via helper functions.
//! This module provides low-level access to ESP-IDF network interface management.
//! Also handles IP_EVENT events (got_ip, lost_ip, etc.)

const std = @import("std");

// Import C helper functions
const c = @cImport({
    @cInclude("netif_helper.h");
});

// ============================================================================
// Event Types
// ============================================================================

/// Event type constants (from C header)
const EVT_DHCP_BOUND: c_int = 1;
const EVT_DHCP_RENEWED: c_int = 2;
const EVT_IP_LOST: c_int = 3;
const EVT_STATIC_IP_SET: c_int = 4;
const EVT_AP_STA_ASSIGNED: c_int = 5;

/// IPv4 address type
pub const Ipv4 = [4]u8;

/// Interface name type
pub const IfName = [16]u8;

/// DHCP bound event data
pub const DhcpBoundData = struct {
    interface: IfName,
    ip: Ipv4,
    netmask: Ipv4,
    gateway: Ipv4,
    dns_main: Ipv4,
    dns_backup: Ipv4,
    lease_time: u32,

    pub fn getInterfaceName(self: *const DhcpBoundData) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.interface, 0) orelse self.interface.len;
        return self.interface[0..len];
    }
};

/// IP lost event data
pub const IpLostData = struct {
    interface: IfName,

    pub fn getInterfaceName(self: *const IpLostData) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.interface, 0) orelse self.interface.len;
        return self.interface[0..len];
    }
};

/// AP STA assigned event data
pub const ApStaAssignedData = struct {
    mac: [6]u8,
    ip: Ipv4,
};

/// Network event
pub const Event = union(enum) {
    /// DHCP lease acquired (full IP configuration)
    dhcp_bound: DhcpBoundData,
    /// DHCP lease renewed (IP didn't change)
    dhcp_renewed: DhcpBoundData,
    /// IP lost
    ip_lost: IpLostData,
    /// Static IP set
    static_ip_set: IpLostData,
    /// AP mode: assigned IP to station
    ap_sta_assigned: ApStaAssignedData,
};

// ============================================================================
// Network Interface Types
// ============================================================================

/// Network interface state
pub const State = enum(u8) {
    down = 0,
    up = 1,
    connected = 2,
};

/// DHCP mode
pub const DhcpMode = enum(u8) {
    disabled = 0,
    client = 1,
    server = 2,
};

/// Network interface info (matches C struct)
pub const Info = extern struct {
    name: [16]u8,
    name_len: u8,
    mac: [6]u8,
    state: u8,
    dhcp: u8,
    ip: [4]u8,
    netmask: [4]u8,
    gateway: [4]u8,
    dns_main: [4]u8,
    dns_backup: [4]u8,

    /// Get interface name as slice
    pub fn getName(self: *const Info) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Get state enum
    pub fn getState(self: *const Info) State {
        return @enumFromInt(self.state);
    }

    /// Get DHCP mode enum
    pub fn getDhcpMode(self: *const Info) DhcpMode {
        return @enumFromInt(self.dhcp);
    }
};

/// Get number of registered network interfaces
pub fn count() usize {
    const cnt = c.netif_helper_count();
    return if (cnt < 0) 0 else @intCast(cnt);
}

/// Get interface name by index
pub fn getName(index: usize, buf: []u8) []const u8 {
    const len = c.netif_helper_get_name(@intCast(index), buf.ptr, @intCast(buf.len));
    return if (len <= 0) "" else buf[0..@intCast(len)];
}

/// Get interface info by name
pub fn getInfo(name: []const u8) ?Info {
    var name_buf: [17:0]u8 = undefined;
    const len = @min(name.len, 16);
    @memcpy(name_buf[0..len], name[0..len]);
    name_buf[len] = 0;

    var info: Info = undefined;
    const ret = c.netif_helper_get_info(&name_buf, @ptrCast(&info));
    return if (ret == 0) info else null;
}

/// Get default interface name
pub fn getDefault(buf: []u8) []const u8 {
    const len = c.netif_helper_get_default(buf.ptr, @intCast(buf.len));
    return if (len <= 0) "" else buf[0..@intCast(len)];
}

/// Set default interface
pub fn setDefault(name: []const u8) void {
    var name_buf: [17:0]u8 = undefined;
    const len = @min(name.len, 16);
    @memcpy(name_buf[0..len], name[0..len]);
    name_buf[len] = 0;
    c.netif_helper_set_default(&name_buf);
}

/// Bring interface up
pub fn up(name: []const u8) void {
    var name_buf: [17:0]u8 = undefined;
    const len = @min(name.len, 16);
    @memcpy(name_buf[0..len], name[0..len]);
    name_buf[len] = 0;
    c.netif_helper_up(&name_buf);
}

/// Bring interface down
pub fn down(name: []const u8) void {
    var name_buf: [17:0]u8 = undefined;
    const len = @min(name.len, 16);
    @memcpy(name_buf[0..len], name[0..len]);
    name_buf[len] = 0;
    c.netif_helper_down(&name_buf);
}

/// Get DNS servers (primary, secondary)
pub fn getDns() struct { [4]u8, [4]u8 } {
    var primary: [4]u8 = undefined;
    var secondary: [4]u8 = undefined;
    c.netif_helper_get_dns(&primary, &secondary);
    return .{ primary, secondary };
}

/// Set DNS servers
pub fn setDns(primary: [4]u8, secondary: ?[4]u8) void {
    if (secondary) |sec| {
        c.netif_helper_set_dns(&primary, &sec);
    } else {
        c.netif_helper_set_dns(&primary, null);
    }
}

// ============================================================================
// Static IP Configuration
// ============================================================================

/// Set static IP on interface (disables DHCP client)
pub fn setStaticIp(name: []const u8, ip: [4]u8, netmask: [4]u8, gateway: [4]u8) !void {
    var name_buf: [17:0]u8 = undefined;
    const len = @min(name.len, 16);
    @memcpy(name_buf[0..len], name[0..len]);
    name_buf[len] = 0;

    const ret = c.netif_helper_set_static_ip(&name_buf, &ip, &netmask, &gateway);
    if (ret != 0) {
        return error.SetStaticIpFailed;
    }
}

/// Enable DHCP client on interface
pub fn enableDhcpClient(name: []const u8) !void {
    var name_buf: [17:0]u8 = undefined;
    const len = @min(name.len, 16);
    @memcpy(name_buf[0..len], name[0..len]);
    name_buf[len] = 0;

    const ret = c.netif_helper_enable_dhcp_client(&name_buf);
    if (ret != 0) {
        return error.EnableDhcpClientFailed;
    }
}

// ============================================================================
// DHCP Server Functions (for AP mode)
// ============================================================================

/// Configure DHCP server IP range
pub fn configureDhcpServer(name: []const u8, start_ip: [4]u8, end_ip: [4]u8, lease_time: u32) !void {
    var name_buf: [17:0]u8 = undefined;
    const len = @min(name.len, 16);
    @memcpy(name_buf[0..len], name[0..len]);
    name_buf[len] = 0;

    const ret = c.netif_helper_configure_dhcps(&name_buf, &start_ip, &end_ip, lease_time);
    if (ret != 0) {
        return error.ConfigureDhcpServerFailed;
    }
}

/// Set DHCP server DNS
pub fn setDhcpServerDns(name: []const u8, dns: [4]u8, dns_backup: ?[4]u8) !void {
    var name_buf: [17:0]u8 = undefined;
    const len = @min(name.len, 16);
    @memcpy(name_buf[0..len], name[0..len]);
    name_buf[len] = 0;

    const ret = if (dns_backup) |backup|
        c.netif_helper_set_dhcps_dns(&name_buf, &dns, &backup)
    else
        c.netif_helper_set_dhcps_dns(&name_buf, &dns, null);

    if (ret != 0) {
        return error.SetDhcpServerDnsFailed;
    }
}

/// Start DHCP server on interface
pub fn startDhcpServer(name: []const u8) !void {
    var name_buf: [17:0]u8 = undefined;
    const len = @min(name.len, 16);
    @memcpy(name_buf[0..len], name[0..len]);
    name_buf[len] = 0;

    const ret = c.netif_helper_start_dhcps(&name_buf);
    if (ret != 0) {
        return error.StartDhcpServerFailed;
    }
}

/// Stop DHCP server on interface
pub fn stopDhcpServer(name: []const u8) void {
    var name_buf: [17:0]u8 = undefined;
    const len = @min(name.len, 16);
    @memcpy(name_buf[0..len], name[0..len]);
    name_buf[len] = 0;

    _ = c.netif_helper_stop_dhcps(&name_buf);
}

// ============================================================================
// Initialization Functions
// ============================================================================

/// Initialize the netif subsystem
/// Must be called before creating any network interfaces.
/// Requires event loop to be initialized first (use idf.event.init()).
pub fn init() !void {
    if (c.netif_helper_init() != 0) {
        return error.InitFailed;
    }
}

/// Create default WiFi STA network interface
pub fn createWifiSta() !void {
    if (c.netif_helper_create_wifi_sta() != 0) {
        return error.InitFailed;
    }
}

/// Create default WiFi AP network interface
pub fn createWifiAp() !void {
    if (c.netif_helper_create_wifi_ap() != 0) {
        return error.InitFailed;
    }
}

// ============================================================================
// Event Functions
// ============================================================================

/// Initialize net event system (registers IP_EVENT handlers)
/// Must be called after event loop and netif are initialized.
pub fn eventInit() !void {
    const ret = c.netif_helper_event_init();
    if (ret != 0) {
        return error.InitFailed;
    }
}

/// Poll for network events (non-blocking)
pub fn pollEvent() ?Event {
    var raw_event: c.net_event_t = undefined;

    if (!c.netif_helper_poll_event(&raw_event)) {
        return null;
    }

    return switch (raw_event.type) {
        EVT_DHCP_BOUND => Event{
            .dhcp_bound = .{
                .interface = raw_event.data.dhcp_bound.interface,
                .ip = raw_event.data.dhcp_bound.ip,
                .netmask = raw_event.data.dhcp_bound.netmask,
                .gateway = raw_event.data.dhcp_bound.gateway,
                .dns_main = raw_event.data.dhcp_bound.dns_main,
                .dns_backup = raw_event.data.dhcp_bound.dns_backup,
                .lease_time = raw_event.data.dhcp_bound.lease_time,
            },
        },
        EVT_DHCP_RENEWED => Event{
            .dhcp_renewed = .{
                .interface = raw_event.data.dhcp_bound.interface,
                .ip = raw_event.data.dhcp_bound.ip,
                .netmask = raw_event.data.dhcp_bound.netmask,
                .gateway = raw_event.data.dhcp_bound.gateway,
                .dns_main = raw_event.data.dhcp_bound.dns_main,
                .dns_backup = raw_event.data.dhcp_bound.dns_backup,
                .lease_time = raw_event.data.dhcp_bound.lease_time,
            },
        },
        EVT_IP_LOST => Event{
            .ip_lost = .{
                .interface = raw_event.data.ip_lost.interface,
            },
        },
        EVT_STATIC_IP_SET => Event{
            .static_ip_set = .{
                .interface = raw_event.data.ip_lost.interface,
            },
        },
        EVT_AP_STA_ASSIGNED => Event{
            .ap_sta_assigned = .{
                .mac = raw_event.data.ap_sta_assigned.mac,
                .ip = raw_event.data.ap_sta_assigned.ip,
            },
        },
        else => null,
    };
}
