//! Net HAL Component (Event-Driven)
//!
//! Provides a unified interface for network interface management and IP events.
//! Handles DHCP events, IP configuration, and DNS management.
//!
//! ## Architecture
//!
//! Net HAL separates IP layer concerns from WiFi/Ethernet link layers:
//! - WiFi HAL: 802.11 layer events (connected, disconnected, auth_failed)
//! - Net HAL: IP layer events (dhcp_bound, ip_lost, dns changes)
//!
//! ## Spec Requirements
//!
//! A Net driver must implement:
//! ```zig
//! pub const net_spec = struct {
//!     pub const Driver = struct {
//!         // Initialization
//!         pub fn init() Error!Self;
//!         pub fn deinit(self: *Self) void;
//!
//!         // Event polling - events pushed via ESP-IDF callbacks
//!         pub fn pollEvent(self: *Self) ?NetEvent;
//!
//!         // Query functions
//!         pub fn getInfo(self: *const Self, name: []const u8) ?NetIfInfo;
//!         pub fn getDns(self: *const Self) struct { Ipv4, Ipv4 };
//!         pub fn getDefault(self: *const Self) ?[]const u8;
//!
//!         // Configuration
//!         pub fn setDns(self: *Self, primary: Ipv4, secondary: ?Ipv4) void;
//!         pub fn setDefault(self: *Self, name: []const u8) void;
//!     };
//!     pub const meta = .{ .id = "net.esp" };
//! };
//! ```
//!
//! ## Example Usage
//!
//! ```zig
//! const Net = hal.net.from(hw.net_spec);
//!
//! var net = try Net.init();
//! defer net.deinit();
//!
//! // In event loop:
//! while (board.nextEvent()) |event| {
//!     switch (event) {
//!         .net => |n| switch (n) {
//!             .dhcp_bound => |info| {
//!                 log.info("Got IP: {}.{}.{}.{}", .{info.ip[0], info.ip[1], info.ip[2], info.ip[3]});
//!                 log.info("DNS: {}.{}.{}.{}", .{info.dns_main[0], info.dns_main[1], info.dns_main[2], info.dns_main[3]});
//!             },
//!             .ip_lost => |iface| log.warn("Lost IP on {s}", .{iface.getInterfaceName()}),
//!             else => {},
//!         },
//!         else => {},
//!     }
//! }
//! ```

const std = @import("std");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _NetMarker = struct {};

/// Check if a type is a Net peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _NetMarker;
}

// ============================================================================
// Types
// ============================================================================

/// IPv4 address as 4 bytes
pub const Ipv4 = [4]u8;

/// MAC address as 6 bytes
pub const Mac = [6]u8;

/// Interface name (null-terminated string in fixed buffer)
pub const IfName = [16]u8;

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
    name: IfName = std.mem.zeroes(IfName),
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

/// DHCP bound event data (full IP configuration)
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

/// AP STA assigned event data (for AP mode)
pub const ApStaAssignedData = struct {
    mac: [6]u8,
    ip: Ipv4,
};

/// Network events
pub const NetEvent = union(enum) {
    /// DHCP lease acquired (full IP configuration)
    dhcp_bound: DhcpBoundData,
    /// DHCP lease renewed (IP didn't change)
    dhcp_renewed: DhcpBoundData,
    /// IP lost
    ip_lost: IpLostData,
    /// Static IP configured
    static_ip_set: IpLostData,
    /// AP mode: assigned IP to a station
    ap_sta_assigned: ApStaAssignedData,
};

// ============================================================================
// DHCP Server Types (for AP mode)
// ============================================================================

/// DHCP Server configuration
pub const DhcpServerConfig = struct {
    /// Start of IP pool (e.g., 192.168.4.2)
    start_ip: Ipv4,
    /// End of IP pool (e.g., 192.168.4.100)
    end_ip: Ipv4,
    /// Gateway IP (usually AP's IP, e.g., 192.168.4.1)
    gateway: Ipv4,
    /// Subnet mask
    netmask: Ipv4 = .{ 255, 255, 255, 0 },
    /// Lease time in seconds
    lease_time_sec: u32 = 7200,
    /// Primary DNS (null = use gateway)
    dns: ?Ipv4 = null,
    /// Secondary DNS
    dns_backup: ?Ipv4 = null,
};

/// Static IP configuration
pub const StaticIpConfig = struct {
    ip: Ipv4,
    netmask: Ipv4 = .{ 255, 255, 255, 0 },
    gateway: Ipv4,
    dns: ?Ipv4 = null,
    dns_backup: ?Ipv4 = null,
};

// ============================================================================
// Net HAL Component
// ============================================================================

/// Net HAL wrapper
/// Wraps a platform-specific Net driver and provides unified event-driven interface
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify required method signatures
        if (!@hasDecl(BaseDriver, "pollEvent")) {
            @compileError("Driver must have pollEvent method");
        }
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _NetMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// The underlying driver
        driver: *Driver,

        /// Cached IP info (updated from events)
        cached_ip: ?Ipv4 = null,
        cached_dns_main: ?Ipv4 = null,
        cached_dns_backup: ?Ipv4 = null,

        // ================================================================
        // Initialization
        // ================================================================

        /// Initialize Net wrapper with driver
        pub fn init(driver: *Driver) Self {
            return .{
                .driver = driver,
            };
        }

        // ================================================================
        // Event Polling
        // ================================================================

        /// Poll for Net events (legacy - events now pushed via callbacks)
        /// Returns the next pending event, or null if none
        pub fn pollEvent(self: *Self) ?NetEvent {
            const driver_event = self.driver.pollEvent() orelse return null;

            // Convert driver event to HAL event type
            const hal_event: NetEvent = switch (driver_event) {
                .dhcp_bound => |data| blk: {
                    self.cached_ip = data.ip;
                    self.cached_dns_main = data.dns_main;
                    self.cached_dns_backup = data.dns_backup;
                    break :blk .{ .dhcp_bound = .{
                        .interface = data.interface,
                        .ip = data.ip,
                        .netmask = data.netmask,
                        .gateway = data.gateway,
                        .dns_main = data.dns_main,
                        .dns_backup = data.dns_backup,
                        .lease_time = data.lease_time,
                    } };
                },
                .dhcp_renewed => |data| blk: {
                    self.cached_ip = data.ip;
                    self.cached_dns_main = data.dns_main;
                    self.cached_dns_backup = data.dns_backup;
                    break :blk .{ .dhcp_renewed = .{
                        .interface = data.interface,
                        .ip = data.ip,
                        .netmask = data.netmask,
                        .gateway = data.gateway,
                        .dns_main = data.dns_main,
                        .dns_backup = data.dns_backup,
                        .lease_time = data.lease_time,
                    } };
                },
                .ip_lost => |data| blk: {
                    self.cached_ip = null;
                    break :blk .{ .ip_lost = .{
                        .interface = data.interface,
                    } };
                },
                .static_ip_set => |data| .{ .static_ip_set = .{
                    .interface = data.interface,
                } },
                .ap_sta_assigned => |data| .{ .ap_sta_assigned = .{
                    .mac = data.mac,
                    .ip = data.ip,
                } },
            };

            return hal_event;
        }

        // ================================================================
        // Query Functions
        // ================================================================

        /// Get interface info by name
        pub fn getInfo(self: *const Self, name: []const u8) ?NetIfInfo {
            if (@hasDecl(Driver, "getInfo")) {
                const driver_info = self.driver.getInfo(name) orelse return null;
                // Convert driver's NetIfInfo to HAL's NetIfInfo (structurally identical)
                return .{
                    .name = driver_info.name,
                    .name_len = driver_info.name_len,
                    .mac = driver_info.mac,
                    .state = @enumFromInt(@intFromEnum(driver_info.state)),
                    .dhcp = @enumFromInt(@intFromEnum(driver_info.dhcp)),
                    .ip = driver_info.ip,
                    .netmask = driver_info.netmask,
                    .gateway = driver_info.gateway,
                    .dns_main = driver_info.dns_main,
                    .dns_backup = driver_info.dns_backup,
                };
            }
            return null;
        }

        /// Get DNS servers (primary, secondary)
        pub fn getDns(self: *const Self) struct { Ipv4, Ipv4 } {
            // Prefer cached values
            if (self.cached_dns_main) |main| {
                return .{ main, self.cached_dns_backup orelse .{ 0, 0, 0, 0 } };
            }
            // Fall back to driver query
            if (@hasDecl(Driver, "getDns")) {
                return self.driver.getDns();
            }
            return .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } };
        }

        /// Get current IP address (cached from events)
        pub fn getIp(self: *const Self) ?Ipv4 {
            return self.cached_ip;
        }

        /// Get default interface name
        pub fn getDefault(self: *const Self, buf: []u8) []const u8 {
            if (@hasDecl(Driver, "getDefault")) {
                return self.driver.getDefault(buf);
            }
            return "";
        }

        // ================================================================
        // Configuration Functions
        // ================================================================

        /// Set DNS servers
        pub fn setDns(self: *Self, primary: Ipv4, secondary: ?Ipv4) void {
            if (@hasDecl(Driver, "setDns")) {
                self.driver.setDns(primary, secondary);
            }
        }

        /// Set default interface
        pub fn setDefault(self: *Self, name: []const u8) void {
            if (@hasDecl(Driver, "setDefault")) {
                self.driver.setDefault(name);
            }
        }

        // ================================================================
        // Static IP Configuration
        // ================================================================

        /// Set static IP on interface (disables DHCP client)
        pub fn setStaticIp(self: *Self, interface: []const u8, config: StaticIpConfig) !void {
            if (@hasDecl(Driver, "setStaticIp")) {
                return self.driver.setStaticIp(interface, config);
            }
            return error.NotSupported;
        }

        /// Enable DHCP client on interface
        pub fn enableDhcpClient(self: *Self, interface: []const u8) !void {
            if (@hasDecl(Driver, "enableDhcpClient")) {
                return self.driver.enableDhcpClient(interface);
            }
            return error.NotSupported;
        }

        // ================================================================
        // DHCP Server (for AP mode)
        // ================================================================

        /// Set interface IP (for AP mode, before starting DHCP server)
        pub fn setInterfaceIp(self: *Self, interface: []const u8, ip: Ipv4, netmask: Ipv4, gateway: Ipv4) !void {
            if (@hasDecl(Driver, "setInterfaceIp")) {
                return self.driver.setInterfaceIp(interface, ip, netmask, gateway);
            }
            return error.NotSupported;
        }

        /// Configure DHCP server (for AP mode)
        pub fn configureDhcpServer(self: *Self, interface: []const u8, config: DhcpServerConfig) !void {
            if (@hasDecl(Driver, "configureDhcpServer")) {
                // Convert HAL DhcpServerConfig to driver's type (structurally identical)
                return self.driver.configureDhcpServer(interface, .{
                    .start_ip = config.start_ip,
                    .end_ip = config.end_ip,
                    .gateway = config.gateway,
                    .netmask = config.netmask,
                    .lease_time_sec = config.lease_time_sec,
                    .dns = config.dns,
                    .dns_backup = config.dns_backup,
                });
            }
            return error.NotSupported;
        }

        /// Start DHCP server on interface
        pub fn startDhcpServer(self: *Self, interface: []const u8) !void {
            if (@hasDecl(Driver, "startDhcpServer")) {
                return self.driver.startDhcpServer(interface);
            }
            return error.NotSupported;
        }

        /// Stop DHCP server on interface
        pub fn stopDhcpServer(self: *Self, interface: []const u8) void {
            if (@hasDecl(Driver, "stopDhcpServer")) {
                self.driver.stopDhcpServer(interface);
            }
        }

        /// Get list of DHCP leases (for AP mode).
        /// Returns `null` if the platform does not support lease queries.
        /// Returns empty slice if supported but no leases currently exist.
        pub fn getDhcpLeases(self: *const Self, interface: []const u8) ?[]const ApStaAssignedData {
            if (@hasDecl(Driver, "getDhcpLeases")) {
                return self.driver.getDhcpLeases(interface);
            }
            return null;
        }

        // ================================================================
        // Utility Methods
        // ================================================================

        /// Format IP address as string
        pub fn formatIp(ip: Ipv4) [15]u8 {
            var buf: [15]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] }) catch {
                return "0.0.0.0        ".*;
            };
            return buf;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Net HAL basic operations" {
    // Mock driver for testing
    const MockDriver = struct {
        const Self = @This();

        pending_event: ?NetEvent = null,

        pub fn pollEvent(self: *Self) ?NetEvent {
            const event = self.pending_event;
            self.pending_event = null;
            return event;
        }

        pub fn getDns(_: *const Self) struct { Ipv4, Ipv4 } {
            return .{ .{ 8, 8, 8, 8 }, .{ 8, 8, 4, 4 } };
        }
    };

    const mock_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "net.test" };
    };

    const TestNet = from(mock_spec);

    var driver = MockDriver{};
    var net = TestNet.init(&driver);

    // Initially no events
    try std.testing.expect(net.pollEvent() == null);

    // Simulate DHCP bound event
    driver.pending_event = NetEvent{
        .dhcp_bound = .{
            .interface = "sta\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*,
            .ip = .{ 192, 168, 1, 100 },
            .netmask = .{ 255, 255, 255, 0 },
            .gateway = .{ 192, 168, 1, 1 },
            .dns_main = .{ 192, 168, 1, 1 },
            .dns_backup = .{ 8, 8, 8, 8 },
            .lease_time = 3600,
        },
    };

    // Poll event
    const event = net.pollEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(Ipv4{ 192, 168, 1, 100 }, event.?.dhcp_bound.ip);

    // Check cached IP
    try std.testing.expect(net.getIp() != null);
    try std.testing.expectEqual(Ipv4{ 192, 168, 1, 100 }, net.getIp().?);

    // Check cached DNS
    const dns = net.getDns();
    try std.testing.expectEqual(Ipv4{ 192, 168, 1, 1 }, dns[0]);
}
