//! WebSim Net Simulation Driver
//!
//! Simulates network interface management and IP events.
//! Monitors WiFi connection state and emits DHCP events:
//!   WiFi connected → 200ms delay → dhcp_bound event
//!   WiFi disconnected → ip_lost event
//!
//! Uses SharedState for:
//!   - Reading wifi_connected (from WiFi driver)
//!   - Writing net_has_ip (for JS UI display)
//!   - net_ip / net_gateway / net_dns (simulated addresses)

const std = @import("std");
const state_mod = @import("state.zig");
const shared = &state_mod.state;

/// IPv4 address
pub const Ipv4 = [4]u8;

/// Interface name
pub const IfName = [16]u8;

/// DHCP delay after WiFi connects (milliseconds)
const DHCP_DELAY_MS: u64 = 200;

/// DHCP bound event data (structurally compatible with HAL net)
pub const DhcpBoundData = struct {
    interface: IfName,
    ip: Ipv4,
    netmask: Ipv4,
    gateway: Ipv4,
    dns_main: Ipv4,
    dns_backup: Ipv4,
    lease_time: u32,
};

/// IP lost event data
pub const IpLostData = struct {
    interface: IfName,
};

/// AP STA assigned data
pub const ApStaAssignedData = struct {
    mac: [6]u8,
    ip: Ipv4,
};

/// Network events (driver's own type, converted by HAL wrapper)
pub const NetEvent = union(enum) {
    dhcp_bound: DhcpBoundData,
    dhcp_renewed: DhcpBoundData,
    ip_lost: IpLostData,
    static_ip_set: IpLostData,
    ap_sta_assigned: ApStaAssignedData,
};

/// Internal state machine
const State = enum {
    no_ip,
    waiting_dhcp,
    has_ip,
};

/// Simulated Net driver for WebSim.
///
/// Satisfies hal.net Driver required interface:
/// - pollEvent
/// Plus optional: getInfo, getDns
pub const NetDriver = struct {
    const Self = @This();

    state: State = .no_ip,

    /// Track previous WiFi state for edge detection
    prev_wifi_connected: bool = false,

    /// Timestamp when WiFi connected (for DHCP delay)
    wifi_connect_time_ms: u64 = 0,

    pub fn init() !Self {
        shared.addLog("WebSim: Net driver ready");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    // ================================================================
    // Required: pollEvent
    // ================================================================

    pub fn pollEvent(self: *Self) ?NetEvent {
        const wifi_now = shared.wifi_connected;

        // Edge: WiFi just connected → start DHCP timer
        if (wifi_now and !self.prev_wifi_connected) {
            self.state = .waiting_dhcp;
            self.wifi_connect_time_ms = shared.time_ms;
            self.prev_wifi_connected = true;
        }

        // Edge: WiFi just disconnected → emit ip_lost
        if (!wifi_now and self.prev_wifi_connected) {
            self.prev_wifi_connected = false;
            if (self.state == .has_ip) {
                self.state = .no_ip;
                shared.net_has_ip = false;
                shared.addLog("WebSim: IP lost");
                return NetEvent{ .ip_lost = .{
                    .interface = staIfName(),
                } };
            }
            self.state = .no_ip;
        }

        // State: waiting_dhcp → has_ip after delay
        if (self.state == .waiting_dhcp) {
            const elapsed = shared.time_ms -| self.wifi_connect_time_ms;
            if (elapsed >= DHCP_DELAY_MS) {
                self.state = .has_ip;
                shared.net_has_ip = true;
                shared.addLog("WebSim: DHCP bound — 192.168.1.100");
                return NetEvent{ .dhcp_bound = .{
                    .interface = staIfName(),
                    .ip = shared.net_ip,
                    .netmask = .{ 255, 255, 255, 0 },
                    .gateway = shared.net_gateway,
                    .dns_main = shared.net_dns,
                    .dns_backup = .{ 8, 8, 4, 4 },
                    .lease_time = 3600,
                } };
            }
        }

        return null;
    }

    // ================================================================
    // Optional: getDns
    // ================================================================

    pub fn getDns(_: *const Self) struct { Ipv4, Ipv4 } {
        return .{ shared.net_dns, .{ 8, 8, 4, 4 } };
    }

    // ================================================================
    // Helpers
    // ================================================================

    fn staIfName() IfName {
        var name: IfName = std.mem.zeroes(IfName);
        name[0] = 's';
        name[1] = 't';
        name[2] = 'a';
        return name;
    }
};
