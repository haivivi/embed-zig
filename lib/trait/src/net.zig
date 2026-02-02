//! Network Interface Trait
//!
//! Provides abstraction for network interface management:
//! - Multiple network interfaces (sta, ap, eth, etc.)
//! - Interface state and configuration
//! - DNS server configuration
//! - Routing table management
//!
//! Platform implementations:
//! - ESP32: lib/esp/src/impl/net.zig

const std = @import("std");

/// IPv4 address as 4 bytes
pub const Ipv4 = [4]u8;

/// MAC address as 6 bytes
pub const Mac = [6]u8;

/// Network interface state
pub const NetIfState = enum {
    /// Interface is disabled
    down,
    /// Interface is enabled but no IP
    up,
    /// Interface has IP address
    connected,
};

/// DHCP mode
pub const DhcpMode = enum {
    /// Static IP configuration
    disabled,
    /// DHCP client (get IP from server)
    client,
    /// DHCP server (assign IP to clients)
    server,
};

/// Network interface information
pub const NetIfInfo = struct {
    /// Interface name (e.g., "sta", "ap", "eth")
    name: [16]u8 = std.mem.zeroes([16]u8),
    name_len: u8 = 0,
    /// MAC address
    mac: Mac = std.mem.zeroes(Mac),
    /// Interface state
    state: NetIfState = .down,
    /// DHCP mode
    dhcp: DhcpMode = .disabled,
    /// IP address
    ip: Ipv4 = .{ 0, 0, 0, 0 },
    /// Subnet mask
    netmask: Ipv4 = .{ 0, 0, 0, 0 },
    /// Gateway address
    gateway: Ipv4 = .{ 0, 0, 0, 0 },
    /// Primary DNS server
    dns_main: Ipv4 = .{ 0, 0, 0, 0 },
    /// Secondary DNS server
    dns_backup: Ipv4 = .{ 0, 0, 0, 0 },

    /// Get interface name as slice
    pub fn getName(self: *const NetIfInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Set interface name from slice
    pub fn setName(self: *NetIfInfo, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, 16));
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = len;
    }
};

/// Route entry
pub const Route = struct {
    /// Destination network
    dest: Ipv4 = .{ 0, 0, 0, 0 },
    /// Network mask
    mask: Ipv4 = .{ 0, 0, 0, 0 },
    /// Gateway address
    gateway: Ipv4 = .{ 0, 0, 0, 0 },
    /// Interface name
    iface: [16]u8 = std.mem.zeroes([16]u8),
    iface_len: u8 = 0,
    /// Route priority (lower = higher priority)
    metric: u16 = 0,

    /// Get interface name as slice
    pub fn getIface(self: *const Route) []const u8 {
        return self.iface[0..self.iface_len];
    }

    /// Set interface name from slice
    pub fn setIface(self: *Route, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, 16));
        @memcpy(self.iface[0..len], name[0..len]);
        self.iface_len = len;
    }
};

/// Network interface name buffer
pub const IfName = [16]u8;

/// Create IfName from string
pub fn ifName(name: []const u8) IfName {
    var buf: IfName = std.mem.zeroes(IfName);
    const len = @min(name.len, 16);
    @memcpy(buf[0..len], name[0..len]);
    return buf;
}

/// Network Manager trait validation
/// Validates that an implementation provides all required network management functions
pub fn from(comptime Impl: type) type {
    comptime {
        // List all interface names
        // fn list() []const IfName
        _ = @as(*const fn () []const IfName, &Impl.list);

        // Get interface info by name
        // fn get(name: IfName) ?NetIfInfo
        _ = @as(*const fn (IfName) ?NetIfInfo, &Impl.get);

        // Get default interface name
        // fn getDefault() ?IfName
        _ = @as(*const fn () ?IfName, &Impl.getDefault);

        // Set default interface
        // fn setDefault(name: IfName) void
        _ = @as(*const fn (IfName) void, &Impl.setDefault);

        // Enable interface
        // fn up(name: IfName) void
        _ = @as(*const fn (IfName) void, &Impl.up);

        // Disable interface
        // fn down(name: IfName) void
        _ = @as(*const fn (IfName) void, &Impl.down);

        // Get DNS servers (primary, secondary)
        // fn getDns() struct { Ipv4, Ipv4 }
        _ = @as(*const fn () struct { Ipv4, Ipv4 }, &Impl.getDns);

        // Set DNS servers
        // fn setDns(primary: Ipv4, secondary: ?Ipv4) void
        _ = @as(*const fn (Ipv4, ?Ipv4) void, &Impl.setDns);

        // Add route
        // fn addRoute(route: Route) void
        _ = @as(*const fn (Route) void, &Impl.addRoute);

        // Delete route by destination and mask
        // fn delRoute(dest: Ipv4, mask: Ipv4) void
        _ = @as(*const fn (Ipv4, Ipv4) void, &Impl.delRoute);
    }
    return Impl;
}

// =========== Helper Functions ===========

/// Format IPv4 address to string
pub fn formatIpv4(ip: Ipv4) [15]u8 {
    var buf: [15]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] }) catch unreachable;
    return buf;
}

/// Parse IPv4 address from string
pub fn parseIpv4(str: []const u8) ?Ipv4 {
    var addr: Ipv4 = undefined;
    var idx: usize = 0;
    var num: u16 = 0;
    var dots: u8 = 0;

    for (str) |ch| {
        if (ch >= '0' and ch <= '9') {
            num = num * 10 + (ch - '0');
            if (num > 255) return null;
        } else if (ch == '.') {
            if (idx >= 4) return null;
            addr[idx] = @intCast(num);
            idx += 1;
            num = 0;
            dots += 1;
        } else {
            return null;
        }
    }

    if (dots != 3 or idx != 3) return null;
    addr[3] = @intCast(num);
    return addr;
}

// =========== Tests ===========

test "NetIfInfo name helpers" {
    var info = NetIfInfo{};
    info.setName("sta");
    try std.testing.expectEqualStrings("sta", info.getName());
}

test "Route iface helpers" {
    var route = Route{};
    route.setIface("eth0");
    try std.testing.expectEqualStrings("eth0", route.getIface());
}

test "ifName helper" {
    const name = ifName("sta");
    try std.testing.expectEqual(@as(u8, 's'), name[0]);
    try std.testing.expectEqual(@as(u8, 't'), name[1]);
    try std.testing.expectEqual(@as(u8, 'a'), name[2]);
    try std.testing.expectEqual(@as(u8, 0), name[3]);
}

test "parseIpv4" {
    const addr = parseIpv4("192.168.4.1").?;
    try std.testing.expectEqual(@as(u8, 192), addr[0]);
    try std.testing.expectEqual(@as(u8, 168), addr[1]);
    try std.testing.expectEqual(@as(u8, 4), addr[2]);
    try std.testing.expectEqual(@as(u8, 1), addr[3]);

    try std.testing.expectEqual(@as(?Ipv4, null), parseIpv4("invalid"));
    try std.testing.expectEqual(@as(?Ipv4, null), parseIpv4("256.1.1.1"));
}
