//! Net Implementation for BK7258
//!
//! board.zig's nextEvent() polls both wifi and net drivers.
//! WiFi events (.connected/.disconnected) -> WiFi driver pollEvent
//! Net events (.got_ip/.dhcp_timeout) -> Net driver pollEvent
//! Both read from the same armino C-side event queue.

const armino = @import("../../armino/src/armino.zig");

// ============================================================================
// Types
// ============================================================================

pub const NetEvent = union(enum) {
    dhcp_bound: DhcpBoundData,
    dhcp_renewed: DhcpBoundData,
    ip_lost: IpLostData,
    static_ip_set: IpLostData,
    ap_sta_assigned: ApStaAssignedData,
};

pub const DhcpBoundData = struct {
    interface: [16]u8 = .{0} ** 16,
    ip: [4]u8,
    netmask: [4]u8,
    gateway: [4]u8,
    dns_main: [4]u8,
    dns_backup: [4]u8,
    lease_time: u32,
};

pub const IpLostData = struct {
    interface: [16]u8 = .{0} ** 16,

    pub fn getInterfaceName(self: *const IpLostData) []const u8 {
        const len = @import("std").mem.indexOfScalar(u8, &self.interface, 0) orelse self.interface.len;
        return self.interface[0..len];
    }
};

pub const ApStaAssignedData = struct {
    mac: [6]u8 = .{0} ** 6,
    ip: [4]u8 = .{0} ** 4,
};

// ============================================================================
// NetDriver
// ============================================================================

pub const NetDriver = struct {
    const Self = @This();
    const event_dispatch = @import("event_dispatch.zig");

    pub const CallbackType = *const fn (?*anyopaque, NetEvent) void;
    pub const EventCallback = CallbackType;
    pub const EventType = NetEvent;
    pub const Error = error{InitFailed};

    initialized: bool = false,
    use_callback: bool = false,

    pub fn init() Error!Self {
        return .{ .initialized = true };
    }

    /// Initialize with callback — events delivered directly to callback
    pub fn initWithCallback(callback: EventCallback, ctx: ?*anyopaque) Error!Self {
        event_dispatch.setNetCallback(callback, ctx);
        return .{ .initialized = true, .use_callback = true };
    }

    pub fn deinit(self: *Self) void {
        if (self.use_callback) {
            event_dispatch.clearNetCallback();
        }
        self.initialized = false;
    }

    /// Poll events via shared dispatcher (avoids dual-poll from same C queue).
    pub fn pollEvent(_: *Self) ?NetEvent {
        return event_dispatch.popNet();
    }
};

pub const net_spec = struct {
    pub const Driver = NetDriver;
    pub const meta = .{ .id = "net.bk" };
};
