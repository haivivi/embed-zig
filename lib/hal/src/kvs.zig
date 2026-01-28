//! Key-Value Store Hardware Abstraction Layer
//!
//! Provides a platform-independent interface for persistent key-value storage:
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   board.kvs.setU32("counter", 42)      │
//! │   const val = board.kvs.getU32("cnt") │
//! ├─────────────────────────────────────────┤
//! │ Kvs(spec)  ← HAL wrapper               │
//! │   - Type-safe get/set                   │
//! │   - String and numeric types            │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← storage impl   │
//! │   - getU32(), setU32()                  │
//! │   - getString(), setString()            │
//! │   - commit()                            │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // Define spec with driver and metadata
//! const kvs_spec = struct {
//!     pub const Driver = NvsDriver;
//!     pub const meta = hal.spec.Meta{ .id = "kvs.main" };
//! };
//!
//! // Create HAL wrapper
//! const MyKvs = hal.Kvs(kvs_spec);
//! var kvs = MyKvs.init(&driver_instance);
//!
//! // Use unified interface
//! try kvs.setU32("boot_count", 42);
//! const count = try kvs.getU32("boot_count");
//! try kvs.commit();
//! ```

const std = @import("std");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _KvsMarker = struct {};

/// Check if a type is a Kvs peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _KvsMarker;
}

// ============================================================================
// Error Types
// ============================================================================

pub const KvsError = error{
    NotFound,
    BufferTooSmall,
    InvalidKey,
    StorageFull,
    WriteError,
    ReadError,
};

// ============================================================================
// Kvs HAL Wrapper
// ============================================================================

/// Key-Value Store HAL component
///
/// Wraps a low-level Driver and provides:
/// - Type-safe get/set for common types
/// - String storage
/// - Commit/flush support
///
/// spec must define:
/// - `Driver`: struct implementing kvs interface
/// - `meta`: spec.Meta with component id
///
/// Driver required methods:
/// - `fn getU32(self: *Self, key: []const u8) !u32`
/// - `fn setU32(self: *Self, key: []const u8, value: u32) !void`
/// - `fn getString(self: *Self, key: []const u8, buf: []u8) ![]const u8`
/// - `fn setString(self: *Self, key: []const u8, value: []const u8) !void`
/// - `fn commit(self: *Self) !void`
///
/// Driver optional methods:
/// - `fn getI32(self: *Self, key: []const u8) !i32`
/// - `fn setI32(self: *Self, key: []const u8, value: i32) !void`
/// - `fn erase(self: *Self, key: []const u8) !void`
/// - `fn eraseAll(self: *Self) !void`
///
/// Example:
/// ```zig
/// const kvs_spec = struct {
///     pub const Driver = NvsDriver;
///     pub const meta = hal.spec.Meta{ .id = "kvs.main" };
/// };
/// const MyKvs = kvs.from(kvs_spec);
/// ```
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify required method signatures
        _ = @as(*const fn (*BaseDriver, []const u8) KvsError!u32, &BaseDriver.getU32);
        _ = @as(*const fn (*BaseDriver, []const u8, u32) KvsError!void, &BaseDriver.setU32);
        _ = @as(*const fn (*BaseDriver, []const u8, []u8) KvsError![]const u8, &BaseDriver.getString);
        _ = @as(*const fn (*BaseDriver, []const u8, []const u8) KvsError!void, &BaseDriver.setString);
        _ = @as(*const fn (*BaseDriver) KvsError!void, &BaseDriver.commit);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _KvsMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// The underlying driver instance
        driver: *Driver,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        // ----- U32 Operations -----

        /// Get unsigned 32-bit integer
        pub fn getU32(self: *Self, key: []const u8) !u32 {
            return self.driver.getU32(key);
        }

        /// Set unsigned 32-bit integer
        pub fn setU32(self: *Self, key: []const u8, value: u32) !void {
            return self.driver.setU32(key, value);
        }

        /// Get U32 with default value if not found
        pub fn getU32OrDefault(self: *Self, key: []const u8, default: u32) u32 {
            return self.getU32(key) catch default;
        }

        // ----- I32 Operations -----

        /// Get signed 32-bit integer
        pub fn getI32(self: *Self, key: []const u8) !i32 {
            if (@hasDecl(Driver, "getI32")) {
                return self.driver.getI32(key);
            } else {
                // Fallback: store as U32 with bit cast
                const u_val = try self.driver.getU32(key);
                return @bitCast(u_val);
            }
        }

        /// Set signed 32-bit integer
        pub fn setI32(self: *Self, key: []const u8, value: i32) !void {
            if (@hasDecl(Driver, "setI32")) {
                return self.driver.setI32(key, value);
            } else {
                // Fallback: store as U32 with bit cast
                const u_val: u32 = @bitCast(value);
                return self.driver.setU32(key, u_val);
            }
        }

        /// Get I32 with default value if not found
        pub fn getI32OrDefault(self: *Self, key: []const u8, default: i32) i32 {
            return self.getI32(key) catch default;
        }

        // ----- String Operations -----

        /// Get string value into provided buffer
        /// Returns slice of buffer containing the string
        pub fn getString(self: *Self, key: []const u8, buf: []u8) ![]const u8 {
            return self.driver.getString(key, buf);
        }

        /// Set string value
        pub fn setString(self: *Self, key: []const u8, value: []const u8) !void {
            return self.driver.setString(key, value);
        }

        // ----- Bool Operations (convenience) -----

        /// Get boolean value
        pub fn getBool(self: *Self, key: []const u8) !bool {
            const val = try self.getU32(key);
            return val != 0;
        }

        /// Set boolean value
        pub fn setBool(self: *Self, key: []const u8, value: bool) !void {
            return self.setU32(key, if (value) 1 else 0);
        }

        /// Get bool with default value if not found
        pub fn getBoolOrDefault(self: *Self, key: []const u8, default: bool) bool {
            return self.getBool(key) catch default;
        }

        // ----- Storage Operations -----

        /// Commit/flush changes to persistent storage
        pub fn commit(self: *Self) !void {
            return self.driver.commit();
        }

        /// Erase a single key
        pub fn erase(self: *Self, key: []const u8) !void {
            if (@hasDecl(Driver, "erase")) {
                return self.driver.erase(key);
            } else {
                // Fallback: no-op or error
                return error.ReadError;
            }
        }

        /// Erase all keys in namespace
        pub fn eraseAll(self: *Self) !void {
            if (@hasDecl(Driver, "eraseAll")) {
                return self.driver.eraseAll();
            } else {
                return error.ReadError;
            }
        }

        // ----- Counter Convenience -----

        /// Increment a U32 counter and return new value
        pub fn increment(self: *Self, key: []const u8) !u32 {
            const current = self.getU32OrDefault(key, 0);
            const new_val = current +| 1; // Saturating add
            try self.setU32(key, new_val);
            return new_val;
        }

        /// Decrement a U32 counter and return new value
        pub fn decrement(self: *Self, key: []const u8) !u32 {
            const current = self.getU32OrDefault(key, 0);
            const new_val = current -| 1; // Saturating sub
            try self.setU32(key, new_val);
            return new_val;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Kvs with mock driver" {
    const MockDriver = struct {
        const Entry = struct {
            key: [32]u8 = undefined,
            key_len: usize = 0,
            u32_val: ?u32 = null,
            str_val: ?[64]u8 = null,
            str_len: usize = 0,
        };

        entries: [16]Entry = [_]Entry{.{}} ** 16,
        commit_count: u32 = 0,

        fn findEntry(self: *@This(), key: []const u8) ?*Entry {
            for (&self.entries) |*entry| {
                if (entry.key_len == key.len and
                    std.mem.eql(u8, entry.key[0..entry.key_len], key))
                {
                    return entry;
                }
            }
            return null;
        }

        fn findOrCreateEntry(self: *@This(), key: []const u8) !*Entry {
            if (self.findEntry(key)) |entry| return entry;

            // Find empty slot
            for (&self.entries) |*entry| {
                if (entry.key_len == 0) {
                    @memcpy(entry.key[0..key.len], key);
                    entry.key_len = key.len;
                    return entry;
                }
            }
            return error.StorageFull;
        }

        pub fn getU32(self: *@This(), key: []const u8) !u32 {
            const entry = self.findEntry(key) orelse return error.NotFound;
            return entry.u32_val orelse error.NotFound;
        }

        pub fn setU32(self: *@This(), key: []const u8, value: u32) !void {
            const entry = try self.findOrCreateEntry(key);
            entry.u32_val = value;
        }

        pub fn getString(self: *@This(), key: []const u8, buf: []u8) ![]const u8 {
            const entry = self.findEntry(key) orelse return error.NotFound;
            const str = entry.str_val orelse return error.NotFound;
            if (buf.len < entry.str_len) return error.BufferTooSmall;
            @memcpy(buf[0..entry.str_len], str[0..entry.str_len]);
            return buf[0..entry.str_len];
        }

        pub fn setString(self: *@This(), key: []const u8, value: []const u8) !void {
            const entry = try self.findOrCreateEntry(key);
            if (value.len > 64) return error.StorageFull;
            var str: [64]u8 = undefined;
            @memcpy(str[0..value.len], value);
            entry.str_val = str;
            entry.str_len = value.len;
        }

        pub fn commit(self: *@This()) !void {
            self.commit_count += 1;
        }
    };

    // Define spec
    const kvs_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "kvs.test" };
    };

    const TestKvs = from(kvs_spec);

    var driver = MockDriver{};
    var kvs = TestKvs.init(&driver);

    // Test metadata
    try std.testing.expectEqualStrings("kvs.test", TestKvs.meta.id);

    // Test U32
    try kvs.setU32("counter", 42);
    const val = try kvs.getU32("counter");
    try std.testing.expectEqual(@as(u32, 42), val);

    // Test getU32OrDefault
    const def_val = kvs.getU32OrDefault("nonexistent", 100);
    try std.testing.expectEqual(@as(u32, 100), def_val);

    // Test I32 (fallback via U32)
    try kvs.setI32("signed", -42);
    const i_val = try kvs.getI32("signed");
    try std.testing.expectEqual(@as(i32, -42), i_val);

    // Test Bool
    try kvs.setBool("flag", true);
    const b_val = try kvs.getBool("flag");
    try std.testing.expect(b_val);

    // Test String
    try kvs.setString("name", "hello");
    var buf: [64]u8 = undefined;
    const str = try kvs.getString("name", &buf);
    try std.testing.expectEqualStrings("hello", str);

    // Test commit
    try kvs.commit();
    try std.testing.expectEqual(@as(u32, 1), driver.commit_count);

    // Test increment
    try kvs.setU32("inc_test", 10);
    const new_val = try kvs.increment("inc_test");
    try std.testing.expectEqual(@as(u32, 11), new_val);
}
