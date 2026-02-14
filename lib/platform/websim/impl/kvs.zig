//! WebSim KVS Driver — In-memory key-value store for WASM simulation
//!
//! Stores key-value pairs in WASM linear memory.
//! Satisfies hal.kvs driver interface (getU32/setU32/getString/setString/commit).
//!
//! Data lives in WASM memory only — lost on page reload.
//! For persistence, JS can poll the dirty flag via exports,
//! read entries, and save to localStorage.

/// Maximum number of KVS entries
const MAX_ENTRIES = 32;
/// Maximum key length
const MAX_KEY_LEN = 32;
/// Maximum string value length
const MAX_STR_LEN = 128;

const KvsError = error{
    NotFound,
    BufferTooSmall,
    InvalidKey,
    StorageFull,
    WriteError,
    ReadError,
};

/// Value type tag
const ValueType = enum(u8) {
    empty = 0,
    u32_val = 1,
    string_val = 2,
};

/// A single KVS entry stored in WASM linear memory
const Entry = struct {
    key: [MAX_KEY_LEN]u8 = undefined,
    key_len: u8 = 0,
    value_type: ValueType = .empty,
    u32_val: u32 = 0,
    str_val: [MAX_STR_LEN]u8 = undefined,
    str_len: u8 = 0,
};

/// In-memory KVS driver for WebSim.
///
/// Implements the hal.kvs Driver interface:
/// - getU32 / setU32
/// - getString / setString
/// - commit
/// - erase / eraseAll (optional)
pub const KvsDriver = struct {
    const Self = @This();

    entries: [MAX_ENTRIES]Entry = [_]Entry{.{}} ** MAX_ENTRIES,

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    // ================================================================
    // Required: getU32 / setU32
    // ================================================================

    pub fn getU32(self: *Self, key: []const u8) KvsError!u32 {
        const entry = self.findEntry(key) orelse return error.NotFound;
        if (entry.value_type != .u32_val) return error.NotFound;
        return entry.u32_val;
    }

    pub fn setU32(self: *Self, key: []const u8, value: u32) KvsError!void {
        const entry = try self.findOrCreate(key);
        entry.value_type = .u32_val;
        entry.u32_val = value;
    }

    // ================================================================
    // Required: getString / setString
    // ================================================================

    pub fn getString(self: *Self, key: []const u8, buf: []u8) KvsError![]const u8 {
        const entry = self.findEntry(key) orelse return error.NotFound;
        if (entry.value_type != .string_val) return error.NotFound;
        const len: usize = entry.str_len;
        if (buf.len < len) return error.BufferTooSmall;
        @memcpy(buf[0..len], entry.str_val[0..len]);
        return buf[0..len];
    }

    pub fn setString(self: *Self, key: []const u8, value: []const u8) KvsError!void {
        if (value.len > MAX_STR_LEN) return error.StorageFull;
        const entry = try self.findOrCreate(key);
        entry.value_type = .string_val;
        @memcpy(entry.str_val[0..value.len], value);
        entry.str_len = @intCast(value.len);
    }

    // ================================================================
    // Required: commit
    // ================================================================

    pub fn commit(_: *Self) KvsError!void {
        // In-memory store: no persistence needed.
        // JS can optionally poll entries via exports and save to localStorage.
    }

    // ================================================================
    // Optional: erase / eraseAll
    // ================================================================

    pub fn erase(self: *Self, key: []const u8) KvsError!void {
        const entry = self.findEntry(key) orelse return error.NotFound;
        entry.value_type = .empty;
        entry.key_len = 0;
    }

    pub fn eraseAll(self: *Self) KvsError!void {
        for (&self.entries) |*entry| {
            entry.value_type = .empty;
            entry.key_len = 0;
        }
    }

    // ================================================================
    // Internal helpers
    // ================================================================

    fn findEntry(self: *Self, key: []const u8) ?*Entry {
        for (&self.entries) |*entry| {
            if (entry.value_type != .empty and
                entry.key_len == key.len and
                eql(entry.key[0..entry.key_len], key))
            {
                return entry;
            }
        }
        return null;
    }

    fn findOrCreate(self: *Self, key: []const u8) KvsError!*Entry {
        if (self.findEntry(key)) |entry| return entry;
        if (key.len > MAX_KEY_LEN) return error.InvalidKey;

        // Find empty slot
        for (&self.entries) |*entry| {
            if (entry.value_type == .empty) {
                @memcpy(entry.key[0..key.len], key);
                entry.key_len = @intCast(key.len);
                return entry;
            }
        }
        return error.StorageFull;
    }

    /// Byte-by-byte comparison (no std.mem dependency for freestanding)
    fn eql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x != y) return false;
        }
        return true;
    }
};
