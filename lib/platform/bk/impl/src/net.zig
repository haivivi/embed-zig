//! Net Implementation for BK7258
//!
//! Implements hal.net-compatible NetDriver using Armino netif events.
//! DHCP events (got_ip) come through armino.wifi.popEvent() as .got_ip.

const std = @import("std");
const armino = @import("../../armino/src/armino.zig");

/// Net event — compatible with hal.net event expectations
pub const NetEvent = union(enum) {
    dhcp_bound: DhcpBoundData,
    dhcp_renewed: DhcpBoundData,
    ip_lost: void,
};

pub const DhcpBoundData = struct {
    ip: [4]u8,
    netmask: [4]u8,
    gateway: [4]u8,
    dns_main: [4]u8,
    dns_backup: [4]u8,
    lease_time: u32,
};

/// Net Driver for HAL
pub const NetDriver = struct {
    const Self = @This();

    pub const CallbackType = *const fn (?*anyopaque, NetEvent) void;
    pub const EventType = NetEvent;

    initialized: bool = false,

    pub fn init() !Self {
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        self.initialized = false;
    }

    /// Poll for network events (IP layer)
    /// Maps armino wifi got_ip/dhcp_timeout events to NetEvent
    pub fn pollEvent(_: *Self) ?NetEvent {
        // Check if there's a got_ip event in the WiFi event queue
        const event = armino.wifi.popEvent() orelse return null;
        return switch (event) {
            .got_ip => |ip_info| NetEvent{
                .dhcp_bound = .{
                    .ip = ip_info.ip,
                    .netmask = .{ 255, 255, 255, 0 }, // TODO: get from netif
                    .gateway = .{ 0, 0, 0, 0 }, // TODO: get from netif
                    .dns_main = ip_info.dns,
                    .dns_backup = .{ 0, 0, 0, 0 },
                    .lease_time = 0,
                },
            },
            .dhcp_timeout => NetEvent{ .ip_lost = {} },
            else => null, // WiFi events go to wifi driver, not net
        };
    }
};

/// Net spec for HAL integration
pub const net_spec = struct {
    pub const Driver = NetDriver;
    pub const meta = .{ .id = "net.bk" };
};
