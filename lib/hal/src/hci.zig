//! HCI Transport HAL Component
//!
//! Provides a unified interface for HCI (Host Controller Interface) transport.
//! This is the lowest layer of the BLE stack — a pure byte pipe (fd).
//!
//! The HCI transport is stateless: no queues, no loops, no packet parsing.
//! It simply moves bytes between the Host and the Controller.
//!
//! ## Spec Requirements
//!
//! An HCI transport driver must implement:
//! ```zig
//! pub const hci_spec = struct {
//!     pub const Driver = struct {
//!         // Required — read raw HCI bytes from controller
//!         pub fn read(self: *Self, buf: []u8) error{WouldBlock, HciError}!usize
//!
//!         // Required — write raw HCI bytes to controller
//!         pub fn write(self: *Self, buf: []const u8) error{WouldBlock, HciError}!usize
//!
//!         // Required — poll for readability/writability
//!         pub fn poll(self: *Self, flags: PollFlags, timeout_ms: i32) PollFlags
//!     };
//!     pub const meta = hal.Meta{ .id = "hci.vhci" };
//! };
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const Hci = hal.hci.from(hw.hci_spec);
//! var hci = Hci.init(&driver);
//!
//! // Poll until readable
//! const ready = hci.poll(.{ .readable = true }, 1000);
//! if (ready.readable) {
//!     const n = try hci.read(&buf);
//!     // process buf[0..n]
//! }
//!
//! // Write HCI packet
//! const ready_w = hci.poll(.{ .writable = true }, -1);
//! if (ready_w.writable) {
//!     _ = try hci.write(packet);
//! }
//! ```

const std = @import("std");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _HciMarker = struct {};

/// Check if a type is an HCI transport peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _HciMarker;
}

// ============================================================================
// Types
// ============================================================================

/// Poll flags for HCI transport readiness
pub const PollFlags = packed struct {
    /// Data is available to read
    readable: bool = false,
    /// Transport is ready to accept writes
    writable: bool = false,
    /// Padding to fill byte
    _padding: u6 = 0,
};

/// HCI packet indicator (first byte on UART/VHCI transport)
pub const PacketType = enum(u8) {
    /// HCI Command packet (Host → Controller)
    command = 0x01,
    /// HCI ACL Data packet (bidirectional)
    acl_data = 0x02,
    /// HCI Synchronous Data packet (bidirectional, SCO/eSCO)
    sync_data = 0x03,
    /// HCI Event packet (Controller → Host)
    event = 0x04,
    /// HCI ISO Data packet (bidirectional, BLE CIS/BIS)
    iso_data = 0x05,
};

/// Errors returned by HCI transport operations
pub const Error = error{
    /// Operation would block (non-blocking mode)
    WouldBlock,
    /// Transport-level error (hardware failure, disconnected, etc.)
    HciError,
};

// ============================================================================
// HCI Transport HAL Component
// ============================================================================

/// HCI Transport HAL wrapper
/// Wraps a platform-specific HCI driver and provides a unified fd-like interface.
///
/// The transport layer is intentionally minimal:
/// - No packet parsing (that's L2CAP/Host's job)
/// - No queues (that's Host's job)
/// - No loops (that's Host's job)
/// - Just read/write/poll — like a file descriptor
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };

        // ================================================================
        // Required method signature verification
        // ================================================================

        // read: *Self, []u8 -> Error!usize
        if (!@hasDecl(BaseDriver, "read")) {
            @compileError("HCI Driver must have read(self, buf) method");
        }

        // write: *Self, []const u8 -> Error!usize
        if (!@hasDecl(BaseDriver, "write")) {
            @compileError("HCI Driver must have write(self, buf) method");
        }

        // poll: *Self, PollFlags, i32 -> PollFlags
        if (!@hasDecl(BaseDriver, "poll")) {
            @compileError("HCI Driver must have poll(self, flags, timeout_ms) method");
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
        pub const _hal_marker = _HciMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// The underlying driver
        driver: *Driver,

        // ================================================================
        // Initialization
        // ================================================================

        /// Initialize HCI transport wrapper with driver
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        // ================================================================
        // Transport Operations (fd-like)
        // ================================================================

        /// Read raw HCI data from the controller.
        ///
        /// Returns the number of bytes read into `buf`.
        /// The caller is responsible for parsing the HCI packet indicator
        /// and packet boundaries.
        ///
        /// Returns `error.WouldBlock` if no data is available (non-blocking).
        /// Returns `error.HciError` on transport failure.
        pub fn read(self: *Self, buf: []u8) Error!usize {
            return self.driver.read(buf);
        }

        /// Write raw HCI data to the controller.
        ///
        /// Returns the number of bytes written from `buf`.
        /// The caller must include the HCI packet indicator byte and
        /// properly formatted packet data.
        ///
        /// Returns `error.WouldBlock` if the transport cannot accept data.
        /// Returns `error.HciError` on transport failure.
        pub fn write(self: *Self, buf: []const u8) Error!usize {
            return self.driver.write(buf);
        }

        /// Poll for transport readiness.
        ///
        /// `flags` specifies which conditions to check:
        /// - `.readable = true` — check if data is available to read
        /// - `.writable = true` — check if transport can accept writes
        ///
        /// `timeout_ms`:
        /// -  0 — non-blocking, return immediately
        /// - >0 — wait up to timeout_ms milliseconds
        /// - -1 — wait indefinitely
        ///
        /// Returns a PollFlags with the ready conditions set.
        pub fn poll(self: *Self, flags: PollFlags, timeout_ms: i32) PollFlags {
            return self.driver.poll(flags, timeout_ms);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "HCI transport basic operations" {
    const MockDriver = struct {
        const Self = @This();

        rx_buf: [256]u8 = undefined,
        rx_len: usize = 0,
        tx_buf: [256]u8 = undefined,
        tx_len: usize = 0,
        readable: bool = false,
        writable: bool = true,

        pub fn read(self: *Self, buf: []u8) Error!usize {
            if (!self.readable) return error.WouldBlock;
            const n = @min(buf.len, self.rx_len);
            @memcpy(buf[0..n], self.rx_buf[0..n]);
            self.rx_len = 0;
            self.readable = false;
            return n;
        }

        pub fn write(self: *Self, buf: []const u8) Error!usize {
            if (!self.writable) return error.WouldBlock;
            const n = @min(buf.len, self.tx_buf.len);
            @memcpy(self.tx_buf[0..n], buf[0..n]);
            self.tx_len = n;
            return n;
        }

        pub fn poll(self: *Self, flags: PollFlags, timeout_ms: i32) PollFlags {
            _ = timeout_ms;
            return .{
                .readable = flags.readable and self.readable,
                .writable = flags.writable and self.writable,
            };
        }
    };

    const mock_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "hci.test" };
    };

    const TestHci = from(mock_spec);

    var driver = MockDriver{};
    var hci = TestHci.init(&driver);

    // Initially not readable
    const r1 = hci.poll(.{ .readable = true }, 0);
    try std.testing.expect(!r1.readable);

    // Write should work
    const r2 = hci.poll(.{ .writable = true }, 0);
    try std.testing.expect(r2.writable);

    // Write a command packet
    const cmd = [_]u8{ @intFromEnum(PacketType.command), 0x03, 0x0C, 0x00 }; // HCI Reset
    const written = try hci.write(&cmd);
    try std.testing.expectEqual(@as(usize, 4), written);
    try std.testing.expectEqualSlices(u8, &cmd, driver.tx_buf[0..4]);

    // Simulate controller response
    const evt = [_]u8{ @intFromEnum(PacketType.event), 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00 };
    @memcpy(driver.rx_buf[0..evt.len], &evt);
    driver.rx_len = evt.len;
    driver.readable = true;

    // Now readable
    const r3 = hci.poll(.{ .readable = true }, 0);
    try std.testing.expect(r3.readable);

    // Read the event
    var buf: [256]u8 = undefined;
    const n = try hci.read(&buf);
    try std.testing.expectEqual(@as(usize, 7), n);
    try std.testing.expectEqual(@as(u8, @intFromEnum(PacketType.event)), buf[0]);
}

test "HCI transport WouldBlock" {
    const MockDriver = struct {
        const Self = @This();

        pub fn read(_: *Self, _: []u8) Error!usize {
            return error.WouldBlock;
        }

        pub fn write(_: *Self, _: []const u8) Error!usize {
            return error.WouldBlock;
        }

        pub fn poll(_: *Self, _: PollFlags, _: i32) PollFlags {
            return .{};
        }
    };

    const mock_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "hci.blocked" };
    };

    const TestHci = from(mock_spec);

    var driver = MockDriver{};
    var hci = TestHci.init(&driver);

    // Both operations should return WouldBlock
    try std.testing.expectError(error.WouldBlock, hci.read(&.{}));
    try std.testing.expectError(error.WouldBlock, hci.write(&.{}));

    // Poll returns nothing ready
    const flags = hci.poll(.{ .readable = true, .writable = true }, 0);
    try std.testing.expect(!flags.readable);
    try std.testing.expect(!flags.writable);
}

test "PacketType values match BLE spec" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(PacketType.command));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(PacketType.acl_data));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(PacketType.sync_data));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(PacketType.event));
    try std.testing.expectEqual(@as(u8, 0x05), @intFromEnum(PacketType.iso_data));
}

test "PollFlags packed layout" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(PollFlags));

    const both: PollFlags = .{ .readable = true, .writable = true };
    try std.testing.expect(both.readable);
    try std.testing.expect(both.writable);

    const none: PollFlags = .{};
    try std.testing.expect(!none.readable);
    try std.testing.expect(!none.writable);
}
