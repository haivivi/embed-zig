//! BLE Host HAL Component
//!
//! GAP/GATT-level abstraction boundary for BLE.
//! This is the high-level BLE interface — above HCI/L2CAP/ATT details.
//!
//! Two implementations:
//! 1. Pure Zig stack (via lib/pkg/bluetooth Host + ESP VHCI)
//! 2. Platform native (e.g., CoreBluetooth on macOS — future)
//!
//! ## Spec Requirements
//!
//! A BLE Host driver must implement:
//! ```zig
//! pub const ble_spec = struct {
//!     pub const Driver = struct {
//!         // Required — lifecycle
//!         pub fn start(self: *Self) !void;
//!         pub fn stop(self: *Self) void;
//!
//!         // Required — advertising
//!         pub fn startAdvertising(self: *Self, config: AdvConfig) !void;
//!         pub fn stopAdvertising(self: *Self) !void;
//!
//!         // Required — event polling
//!         pub fn poll(self: *Self, timeout_ms: i32) ?BleEvent;
//!
//!         // Optional — connection management
//!         pub fn disconnect(self: *Self, conn_handle: u16, reason: u8) !void;
//!
//!         // Optional — GATT operations
//!         pub fn notify(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) void;
//!         pub fn indicate(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) void;
//!
//!         // Required — state queries
//!         pub fn getState(self: *const Self) State;
//!         pub fn getConnHandle(self: *const Self) ?u16;
//!     };
//!     pub const meta = hal.Meta{ .id = "ble.host" };
//! };
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const Ble = hal.ble.from(hw.ble_spec);
//! var ble = Ble.init(&driver);
//! try ble.start();
//! try ble.startAdvertising(.{ .adv_data = &ad_bytes });
//! while (true) {
//!     if (ble.poll(1000)) |event| {
//!         switch (event) {
//!             .connected => |info| log.info("Connected: {x}", .{info.conn_handle}),
//!             .disconnected => |info| log.info("Disconnected", .{}),
//!             else => {},
//!         }
//!     }
//! }
//! ```

const std = @import("std");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

const _BleMarker = struct {};

/// Check if a type is a BLE Host peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _BleMarker;
}

// ============================================================================
// Types
// ============================================================================

/// BLE Host state
pub const State = enum {
    uninitialized,
    idle,
    advertising,
    scanning,
    connecting,
    connected,
};

/// BLE event (high-level, GAP/GATT-level)
pub const BleEvent = union(enum) {
    /// Advertising started
    advertising_started: void,
    /// Advertising stopped (manually or due to connection)
    advertising_stopped: void,
    /// A peer connected
    connected: ConnectionInfo,
    /// A peer disconnected
    disconnected: DisconnectionInfo,
    /// Connection attempt failed
    connection_failed: void,
};

/// Connection information
pub const ConnectionInfo = struct {
    conn_handle: u16,
    peer_addr: [6]u8,
    peer_addr_type: u8,
    role: Role,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
};

/// Disconnection information
pub const DisconnectionInfo = struct {
    conn_handle: u16,
    reason: u8,
};

/// BLE role
pub const Role = enum(u8) {
    central = 0x00,
    peripheral = 0x01,
};

/// Advertising configuration
pub const AdvConfig = struct {
    /// Advertising interval (units of 0.625ms)
    interval_min: u16 = 0x0800,
    interval_max: u16 = 0x0800,
    /// Advertising data (max 31 bytes)
    adv_data: []const u8 = &.{},
    /// Scan response data (max 31 bytes)
    scan_rsp_data: []const u8 = &.{},
    /// Channel map (default: all three channels)
    channel_map: u8 = 0x07,
};

// ============================================================================
// BLE Host HAL Component
// ============================================================================

/// BLE Host HAL wrapper
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };

        // Required methods
        if (!@hasDecl(BaseDriver, "start")) {
            @compileError("BLE Driver must have start(self) method");
        }
        if (!@hasDecl(BaseDriver, "stop")) {
            @compileError("BLE Driver must have stop(self) method");
        }
        if (!@hasDecl(BaseDriver, "startAdvertising")) {
            @compileError("BLE Driver must have startAdvertising(self, config) method");
        }
        if (!@hasDecl(BaseDriver, "stopAdvertising")) {
            @compileError("BLE Driver must have stopAdvertising(self) method");
        }
        if (!@hasDecl(BaseDriver, "poll")) {
            @compileError("BLE Driver must have poll(self, timeout_ms) method");
        }
        if (!@hasDecl(BaseDriver, "getState")) {
            @compileError("BLE Driver must have getState(self) method");
        }

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker = _BleMarker;
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        // ================================================================
        // Lifecycle
        // ================================================================

        pub fn start(self: *Self) !void {
            return self.driver.start();
        }

        pub fn stop(self: *Self) void {
            self.driver.stop();
        }

        // ================================================================
        // Advertising
        // ================================================================

        pub fn startAdvertising(self: *Self, config: AdvConfig) !void {
            return self.driver.startAdvertising(config);
        }

        pub fn stopAdvertising(self: *Self) !void {
            return self.driver.stopAdvertising();
        }

        // ================================================================
        // Event Polling
        // ================================================================

        pub fn poll(self: *Self, timeout_ms: i32) ?BleEvent {
            return self.driver.poll(timeout_ms);
        }

        // ================================================================
        // Connection Management
        // ================================================================

        pub fn disconnect(self: *Self, conn_handle: u16, reason: u8) !void {
            if (@hasDecl(Driver, "disconnect")) {
                return self.driver.disconnect(conn_handle, reason);
            }
            return error.NotSupported;
        }

        // ================================================================
        // GATT Operations
        // ================================================================

        pub fn notify(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) void {
            if (@hasDecl(Driver, "notify")) {
                self.driver.notify(conn_handle, attr_handle, value);
            }
        }

        pub fn indicate(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) void {
            if (@hasDecl(Driver, "indicate")) {
                self.driver.indicate(conn_handle, attr_handle, value);
            }
        }

        // ================================================================
        // State Queries
        // ================================================================

        pub fn getState(self: *const Self) State {
            return self.driver.getState();
        }

        pub fn getConnHandle(self: *const Self) ?u16 {
            if (@hasDecl(Driver, "getConnHandle")) {
                return self.driver.getConnHandle();
            }
            return null;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "BLE Host trait validation" {
    const MockDriver = struct {
        const Self = @This();

        state: State = .idle,

        pub fn start(self: *Self) !void {
            self.state = .idle;
        }

        pub fn stop(self: *Self) void {
            self.state = .uninitialized;
        }

        pub fn startAdvertising(self: *Self, _: AdvConfig) !void {
            self.state = .advertising;
        }

        pub fn stopAdvertising(self: *Self) !void {
            self.state = .idle;
        }

        pub fn poll(_: *Self, _: i32) ?BleEvent {
            return null;
        }

        pub fn getState(self: *const Self) State {
            return self.state;
        }

        pub fn getConnHandle(_: *const Self) ?u16 {
            return null;
        }
    };

    const mock_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "ble.test" };
    };

    const TestBle = from(mock_spec);

    var driver = MockDriver{};
    var ble = TestBle.init(&driver);

    try ble.start();
    try std.testing.expectEqual(State.idle, ble.getState());

    try ble.startAdvertising(.{});
    try std.testing.expectEqual(State.advertising, ble.getState());

    try ble.stopAdvertising();
    try std.testing.expectEqual(State.idle, ble.getState());

    try std.testing.expect(ble.poll(0) == null);
    try std.testing.expect(ble.getConnHandle() == null);

    ble.stop();
    try std.testing.expectEqual(State.uninitialized, ble.getState());
}
