//! WiFi HAL Component
//!
//! Provides a unified interface for WiFi station mode operations.
//!
//! ## Spec Requirements
//!
//! A WiFi driver must implement:
//! ```zig
//! pub const wifi_spec = struct {
//!     pub const Driver = struct {
//!         // Required methods
//!         pub fn connect(self: *Self, ssid: []const u8, password: []const u8) Error!void;
//!         pub fn disconnect(self: *Self) void;
//!         pub fn isConnected(self: *const Self) bool;
//!         pub fn getIpAddress(self: *const Self) ?IpAddress;
//!
//!         // Optional methods
//!         pub fn getRssi(self: *const Self) ?i8;   // Signal strength
//!         pub fn getMac(self: *const Self) ?Mac;   // MAC address
//!     };
//!     pub const meta = hal.Meta{ .id = "wifi.main" };
//! };
//! ```
//!
//! ## Example Usage
//!
//! ```zig
//! const Wifi = hal.Wifi(hw.wifi_spec);
//!
//! var wifi = Wifi.init(&driver);
//! try wifi.connect("MySSID", "password");
//!
//! if (wifi.isConnected()) {
//!     if (wifi.getIpAddress()) |ip| {
//!         std.log.info("IP: {}.{}.{}.{}", .{ip[0], ip[1], ip[2], ip[3]});
//!     }
//! }
//! ```

const std = @import("std");


// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _WifiMarker = struct {};

/// Check if a type is a Wifi peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _WifiMarker;
}

// ============================================================================
// Types
// ============================================================================

/// IPv4 address as 4 bytes
pub const IpAddress = [4]u8;

/// MAC address as 6 bytes
pub const Mac = [6]u8;

/// WiFi connection state
pub const State = enum {
    disconnected,
    connecting,
    connected,
    failed,
};

/// WiFi event types for event system integration
pub const WifiEvent = union(enum) {
    /// WiFi connected to AP
    connected: void,
    /// WiFi disconnected from AP
    disconnected: DisconnectReason,
    /// Got IP address
    got_ip: IpAddress,
    /// Connection failed
    failed: FailReason,
    /// RSSI changed significantly
    rssi_changed: i8,
};

/// Reason for disconnection
pub const DisconnectReason = enum {
    user_request,
    auth_failed,
    ap_not_found,
    connection_lost,
    unknown,
};

/// Reason for connection failure
pub const FailReason = enum {
    timeout,
    auth_failed,
    ap_not_found,
    dhcp_failed,
    unknown,
};

/// WiFi connection configuration
pub const ConnectConfig = struct {
    ssid: []const u8,
    password: []const u8,
    timeout_ms: u32 = 30_000,
    /// Auto-reconnect on disconnect
    auto_reconnect: bool = true,
};

/// WiFi status information
pub const Status = struct {
    state: State,
    ip: ?IpAddress,
    rssi: ?i8,
    ssid: ?[]const u8,
};

// ============================================================================
// WiFi HAL Component
// ============================================================================

/// WiFi HAL wrapper
/// Wraps a platform-specific WiFi driver and provides unified interface
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify required method signatures
        _ = @as(*const fn (*BaseDriver, []const u8, []const u8) anyerror!void, &BaseDriver.connect);
        _ = @as(*const fn (*BaseDriver) void, &BaseDriver.disconnect);
        _ = @as(*const fn (*const BaseDriver) bool, &BaseDriver.isConnected);
        _ = @as(*const fn (*const BaseDriver) ?IpAddress, &BaseDriver.getIpAddress);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _WifiMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// The underlying driver
        driver: *Driver,

        /// Current state (tracked by HAL)
        state: State = .disconnected,

        /// Current SSID (if connected)
        current_ssid: ?[]const u8 = null,

        // ================================================================
        // Initialization
        // ================================================================

        /// Initialize WiFi wrapper with driver
        pub fn init(driver: *Driver) Self {
            return .{
                .driver = driver,
            };
        }

        // ================================================================
        // Connection Operations
        // ================================================================

        /// Connect to WiFi network
        pub fn connect(self: *Self, ssid: []const u8, password: []const u8) !void {
            self.state = .connecting;
            self.current_ssid = ssid;

            try self.driver.connect(ssid, password);

            // If connect returns without error, we're connected
            self.state = .connected;
        }

        /// Connect with full configuration
        pub fn connectWithConfig(self: *Self, config: ConnectConfig) !void {
            return self.connect(config.ssid, config.password);
        }

        /// Disconnect from current network
        pub fn disconnect(self: *Self) void {
            self.driver.disconnect();
            self.state = .disconnected;
            self.current_ssid = null;
        }

        // ================================================================
        // Status Queries
        // ================================================================

        /// Check if connected
        pub fn isConnected(self: *const Self) bool {
            return self.driver.isConnected();
        }

        /// Get current IP address (if connected and has IP)
        pub fn getIpAddress(self: *const Self) ?IpAddress {
            return self.driver.getIpAddress();
        }

        /// Get current signal strength in dBm (if supported)
        pub fn getRssi(self: *const Self) ?i8 {
            if (@hasDecl(Driver, "getRssi")) {
                return self.driver.getRssi();
            }
            return null;
        }

        /// Get MAC address (if supported)
        pub fn getMac(self: *const Self) ?Mac {
            if (@hasDecl(Driver, "getMac")) {
                return self.driver.getMac();
            }
            return null;
        }

        /// Get full status information
        pub fn getStatus(self: *const Self) Status {
            return .{
                .state = if (self.isConnected()) .connected else self.state,
                .ip = self.getIpAddress(),
                .rssi = self.getRssi(),
                .ssid = self.current_ssid,
            };
        }

        // ================================================================
        // Utility Methods
        // ================================================================

        /// Get signal quality as percentage (0-100)
        /// Based on RSSI: -50dBm = 100%, -100dBm = 0%
        pub fn getSignalQuality(self: *const Self) ?u8 {
            const rssi = self.getRssi() orelse return null;

            if (rssi >= -50) return 100;
            if (rssi <= -100) return 0;

            // Linear interpolation: -50 to -100 -> 100 to 0
            const quality: i16 = @as(i16, rssi) + 100; // -50 -> 50, -100 -> 0
            return @intCast(@as(u16, @intCast(quality)) * 2);
        }

        /// Format IP address as string (for logging)
        pub fn formatIp(ip: IpAddress) [15]u8 {
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

test "Wifi basic operations" {
    // Mock driver for testing
    const MockDriver = struct {
        const Self = @This();

        connected: bool = false,
        ip: ?IpAddress = null,

        pub fn connect(self: *Self, ssid: []const u8, password: []const u8) !void {
            _ = ssid;
            _ = password;
            self.connected = true;
            self.ip = .{ 192, 168, 1, 100 };
        }

        pub fn disconnect(self: *Self) void {
            self.connected = false;
            self.ip = null;
        }

        pub fn isConnected(self: *const Self) bool {
            return self.connected;
        }

        pub fn getIpAddress(self: *const Self) ?IpAddress {
            return self.ip;
        }

        pub fn getRssi(_: *const Self) ?i8 {
            return -60;
        }
    };

    const mock_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "wifi.test" };
    };

    const TestWifi = from(mock_spec);

    var driver = MockDriver{};
    var wifi = TestWifi.init(&driver);

    // Initially disconnected
    try std.testing.expect(!wifi.isConnected());
    try std.testing.expect(wifi.getIpAddress() == null);

    // Connect
    try wifi.connect("TestSSID", "password");
    try std.testing.expect(wifi.isConnected());

    // Check IP
    const ip = wifi.getIpAddress();
    try std.testing.expect(ip != null);
    try std.testing.expectEqual(IpAddress{ 192, 168, 1, 100 }, ip.?);

    // Check RSSI
    try std.testing.expectEqual(@as(?i8, -60), wifi.getRssi());

    // Check signal quality
    const quality = wifi.getSignalQuality();
    try std.testing.expect(quality != null);
    try std.testing.expectEqual(@as(u8, 80), quality.?); // -60 dBm = 80%

    // Disconnect
    wifi.disconnect();
    try std.testing.expect(!wifi.isConnected());
}

test "Signal quality calculation" {
    // Test edge cases
    const MockDriver = struct {
        const Self = @This();
        rssi: i8 = -75,

        pub fn connect(_: *Self, _: []const u8, _: []const u8) !void {}
        pub fn disconnect(_: *Self) void {}
        pub fn isConnected(_: *const Self) bool {
            return true;
        }
        pub fn getIpAddress(_: *const Self) ?IpAddress {
            return null;
        }
        pub fn getRssi(self: *const Self) ?i8 {
            return self.rssi;
        }
    };

    const mock_spec2 = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "wifi.test2" };
    };

    const TestWifi = from(mock_spec2);

    var driver = MockDriver{};
    var wifi = TestWifi.init(&driver);

    // -75 dBm should be 50%
    driver.rssi = -75;
    try std.testing.expectEqual(@as(?u8, 50), wifi.getSignalQuality());

    // -50 dBm should be 100%
    driver.rssi = -50;
    try std.testing.expectEqual(@as(?u8, 100), wifi.getSignalQuality());

    // -100 dBm should be 0%
    driver.rssi = -100;
    try std.testing.expectEqual(@as(?u8, 0), wifi.getSignalQuality());

    // Better than -50 should be capped at 100%
    driver.rssi = -30;
    try std.testing.expectEqual(@as(?u8, 100), wifi.getSignalQuality());
}
