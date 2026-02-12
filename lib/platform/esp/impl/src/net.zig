//! ESP Network HAL Implementation
//!
//! Implements the Net HAL interface using ESP-IDF esp_netif APIs.
//! Provides network interface management, DNS configuration, and IP events.
//!
//! This is the impl layer that:
//! - Uses idf/net for low-level netif operations
//! - Handles IP_EVENT events (got_ip, lost_ip, etc.)
//! - Provides the Net HAL driver interface

const std = @import("std");
const idf = @import("idf");
const netif = idf.net.netif;

// ============================================================================
// Types (compatible with hal.net)
// ============================================================================

/// IPv4 address
pub const Ipv4 = [4]u8;

/// Network interface name buffer
pub const IfName = [16]u8;

/// MAC address
pub const Mac = [6]u8;

/// Network interface state
pub const NetIfState = enum {
    down,
    up,
    connected,
};

/// DHCP mode
pub const DhcpMode = enum {
    disabled,
    client,
    server,
};

/// Network interface info
pub const NetIfInfo = struct {
    name: [16]u8 = std.mem.zeroes([16]u8),
    name_len: u8 = 0,
    mac: Mac = std.mem.zeroes(Mac),
    state: NetIfState = .down,
    dhcp: DhcpMode = .disabled,
    ip: Ipv4 = .{ 0, 0, 0, 0 },
    netmask: Ipv4 = .{ 0, 0, 0, 0 },
    gateway: Ipv4 = .{ 0, 0, 0, 0 },
    dns_main: Ipv4 = .{ 0, 0, 0, 0 },
    dns_backup: Ipv4 = .{ 0, 0, 0, 0 },

    pub fn getName(self: *const NetIfInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

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

/// Network events (compatible with hal.net.NetEvent)
pub const NetEvent = union(enum) {
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

pub const Error = error{
    InitFailed,
    NotSupported,
    InvalidInterface,
    DhcpServerError,
};

/// Static IP configuration
pub const StaticIpConfig = struct {
    ip: Ipv4,
    netmask: Ipv4 = .{ 255, 255, 255, 0 },
    gateway: Ipv4,
    dns: ?Ipv4 = null,
    dns_backup: ?Ipv4 = null,
};

/// DHCP Server configuration
pub const DhcpServerConfig = struct {
    start_ip: Ipv4,
    end_ip: Ipv4,
    gateway: Ipv4,
    netmask: Ipv4 = .{ 255, 255, 255, 0 },
    lease_time_sec: u32 = 7200,
    dns: ?Ipv4 = null,
    dns_backup: ?Ipv4 = null,
};

// ============================================================================
// Net Driver (HAL-compatible)
// ============================================================================

/// Callback type for event notifications
pub const EventCallback = *const fn (ctx: ?*anyopaque, event: NetEvent) void;

/// Network interface driver for HAL
pub const NetDriver = struct {
    /// Event callback type (exported for HAL access)
    pub const CallbackType = EventCallback;
    /// Event type (exported for HAL access)
    pub const EventType = NetEvent;
    const Self = @This();

    initialized: bool = false,
    use_callback: bool = false,

    /// Convert netif.Event to NetEvent
    fn convertEvent(idf_event: netif.Event) NetEvent {
        return switch (idf_event) {
            .dhcp_bound => |data| NetEvent{
                .dhcp_bound = .{
                    .interface = data.interface,
                    .ip = data.ip,
                    .netmask = data.netmask,
                    .gateway = data.gateway,
                    .dns_main = data.dns_main,
                    .dns_backup = data.dns_backup,
                    .lease_time = data.lease_time,
                },
            },
            .dhcp_renewed => |data| NetEvent{
                .dhcp_renewed = .{
                    .interface = data.interface,
                    .ip = data.ip,
                    .netmask = data.netmask,
                    .gateway = data.gateway,
                    .dns_main = data.dns_main,
                    .dns_backup = data.dns_backup,
                    .lease_time = data.lease_time,
                },
            },
            .ip_lost => |data| NetEvent{
                .ip_lost = .{
                    .interface = data.interface,
                },
            },
            .static_ip_set => |data| NetEvent{
                .static_ip_set = .{
                    .interface = data.interface,
                },
            },
            .ap_sta_assigned => |data| NetEvent{
                .ap_sta_assigned = .{
                    .mac = data.mac,
                    .ip = data.ip,
                },
            },
        };
    }

    /// Stored callback for forwarding events
    var s_event_callback: ?EventCallback = null;
    var s_event_callback_ctx: ?*anyopaque = null;

    /// Internal callback that forwards to user callback
    fn internalCallback(ctx: ?*anyopaque, event: netif.Event) void {
        _ = ctx;
        if (s_event_callback) |callback| {
            callback(s_event_callback_ctx, convertEvent(event));
        }
    }

    /// Initialize network event system with callback (direct push)
    /// Events are delivered directly to the callback from ESP-IDF event handler context.
    pub fn initWithCallback(callback: EventCallback, ctx: ?*anyopaque) Error!Self {
        const idf_event = @import("idf").event;

        // Ensure event loop exists (idempotent)
        idf_event.init() catch {
            return error.InitFailed;
        };

        // Store callback
        s_event_callback = callback;
        s_event_callback_ctx = ctx;

        // Register IP event handlers with callback
        netif.eventInitWithCallback(internalCallback, null) catch {
            s_event_callback = null;
            s_event_callback_ctx = null;
            return error.InitFailed;
        };

        std.log.info("[net] Network event system initialized (callback mode)", .{});

        return .{ .initialized = true, .use_callback = true };
    }

    /// Initialize network event system (polling mode)
    /// @deprecated Use initWithCallback() for direct push
    /// Ensures event loop exists and registers IP event handlers
    pub fn init() Error!Self {
        const idf_event = @import("idf").event;

        // Ensure event loop exists (idempotent)
        idf_event.init() catch {
            return error.InitFailed;
        };

        // Register IP event handlers (legacy queue-based)
        netif.eventInit() catch {
            return error.InitFailed;
        };

        std.log.info("[net] Network event system initialized (polling mode - deprecated)", .{});

        return .{ .initialized = true, .use_callback = false };
    }

    /// Deinitialize (currently no cleanup needed)
    pub fn deinit(self: *Self) void {
        if (self.use_callback) {
            s_event_callback = null;
            s_event_callback_ctx = null;
        }
        self.initialized = false;
    }

    /// Poll for network events (deprecated when using callback mode)
    /// @deprecated Use initWithCallback() for direct push instead of polling
    pub fn pollEvent(self: *Self) ?NetEvent {
        if (self.use_callback) {
            // In callback mode, events go directly to callback, not poll
            return null;
        }
        const idf_event = netif.pollEvent() orelse return null;
        return convertEvent(idf_event);
    }

    /// Get interface info by name
    pub fn getInfo(_: *const Self, name: []const u8) ?NetIfInfo {
        const info = netif.getInfo(name) orelse return null;

        var result = NetIfInfo{};
        result.name = info.name;
        result.name_len = info.name_len;
        result.mac = info.mac;
        result.ip = info.ip;
        result.netmask = info.netmask;
        result.gateway = info.gateway;
        result.dns_main = info.dns_main;
        result.dns_backup = info.dns_backup;

        // Map state
        result.state = switch (info.state) {
            0 => .down,
            1 => .up,
            2 => .connected,
            else => .down,
        };

        // Map DHCP mode
        result.dhcp = switch (info.dhcp) {
            0 => .disabled,
            1 => .client,
            2 => .server,
            else => .disabled,
        };

        return result;
    }

    /// Get DNS servers (primary, secondary)
    pub fn getDns(_: *const Self) struct { Ipv4, Ipv4 } {
        return netif.getDns();
    }

    /// Get default interface name
    pub fn getDefault(_: *const Self, buf: []u8) []const u8 {
        return netif.getDefault(buf);
    }

    /// Set DNS servers
    pub fn setDns(_: *Self, primary: Ipv4, secondary: ?Ipv4) void {
        netif.setDns(primary, secondary);
    }

    /// Set default interface
    pub fn setDefault(_: *Self, name: []const u8) void {
        netif.setDefault(name);
    }

    /// Bring interface up
    pub fn up(_: *Self, name: []const u8) void {
        netif.up(name);
    }

    /// Bring interface down
    pub fn down(_: *Self, name: []const u8) void {
        netif.down(name);
    }

    // ================================================================
    // Static IP Configuration
    // ================================================================

    /// Set static IP on interface (disables DHCP client)
    pub fn setStaticIp(_: *Self, interface: []const u8, config: StaticIpConfig) !void {
        try netif.setStaticIp(interface, config.ip, config.netmask, config.gateway);
        if (config.dns) |dns| {
            netif.setDns(dns, config.dns_backup);
        }
    }

    /// Enable DHCP client on interface
    pub fn enableDhcpClient(_: *Self, interface: []const u8) !void {
        try netif.enableDhcpClient(interface);
    }

    // ================================================================
    // DHCP Server (for AP mode)
    // ================================================================

    /// Set interface IP (for AP mode)
    pub fn setInterfaceIp(_: *Self, interface: []const u8, ip: Ipv4, netmask: Ipv4, gateway: Ipv4) !void {
        try netif.setStaticIp(interface, ip, netmask, gateway);
    }

    /// Configure DHCP server
    pub fn configureDhcpServer(_: *Self, interface: []const u8, config: DhcpServerConfig) !void {
        try netif.configureDhcpServer(interface, config.start_ip, config.end_ip, config.lease_time_sec);
        // Set gateway as DNS if not specified
        const dns = config.dns orelse config.gateway;
        try netif.setDhcpServerDns(interface, dns, config.dns_backup);
    }

    /// Start DHCP server on interface
    pub fn startDhcpServer(_: *Self, interface: []const u8) !void {
        try netif.startDhcpServer(interface);
    }

    /// Stop DHCP server on interface
    pub fn stopDhcpServer(_: *Self, interface: []const u8) void {
        netif.stopDhcpServer(interface);
    }

    /// Get DHCP leases.
    /// ESP-IDF does not expose DHCP lease query APIs — returns null (unknown).
    pub fn getDhcpLeases(_: *const Self, _: []const u8) ?[]const ApStaAssignedData {
        return null;
    }
};

// ============================================================================
// HAL Spec
// ============================================================================

/// Net spec for HAL integration
pub const net_spec = struct {
    pub const Driver = NetDriver;
    pub const meta = .{ .id = "net.esp" };
};

// ============================================================================
// Convenience Functions (for direct use without HAL wrapper)
// ============================================================================

/// Maximum number of interfaces
const MAX_INTERFACES = 4;

/// Static storage for interface names
var interface_names: [MAX_INTERFACES]IfName = undefined;
var interface_count: usize = 0;

/// List all network interface names
pub fn list() []const IfName {
    const count = netif.count();
    interface_count = @min(count, MAX_INTERFACES);

    for (0..interface_count) |i| {
        var name_buf: [16]u8 = undefined;
        const name = netif.getName(i, &name_buf);
        interface_names[i] = std.mem.zeroes(IfName);
        const len = @min(name.len, 16);
        @memcpy(interface_names[i][0..len], name[0..len]);
    }

    return interface_names[0..interface_count];
}

/// Get interface info by name (convenience function)
pub fn get(name: IfName) ?NetIfInfo {
    var name_len: usize = 0;
    for (name, 0..) |ch, i| {
        if (ch == 0) break;
        name_len = i + 1;
    }

    const info = netif.getInfo(name[0..name_len]) orelse return null;

    var result = NetIfInfo{};
    result.name = info.name;
    result.name_len = info.name_len;
    result.mac = info.mac;
    result.ip = info.ip;
    result.netmask = info.netmask;
    result.gateway = info.gateway;
    result.dns_main = info.dns_main;
    result.dns_backup = info.dns_backup;

    result.state = switch (info.state) {
        0 => .down,
        1 => .up,
        2 => .connected,
        else => .down,
    };

    result.dhcp = switch (info.dhcp) {
        0 => .disabled,
        1 => .client,
        2 => .server,
        else => .disabled,
    };

    return result;
}

/// Get default interface name (convenience function)
pub fn getDefaultIf() ?IfName {
    var buf: [16]u8 = undefined;
    const name = netif.getDefault(&buf);
    if (name.len == 0) return null;

    var result: IfName = std.mem.zeroes(IfName);
    @memcpy(result[0..name.len], name);
    return result;
}

/// Get DNS servers (convenience function)
pub fn getDns() struct { Ipv4, Ipv4 } {
    return netif.getDns();
}

/// Set DNS servers (convenience function)
pub fn setDns(primary: Ipv4, secondary: ?Ipv4) void {
    netif.setDns(primary, secondary);
}

/// Initialize driver (convenience function)
pub fn init() Error!NetDriver {
    return NetDriver.init();
}
