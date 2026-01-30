//! Key-Value Store Implementation for ESP32
//!
//! Implements hal.kvs Driver interface using idf.nvs.
//!
//! Usage:
//!   const impl = @import("impl");
//!   const hal = @import("hal");
//!
//!   const kvs_spec = struct {
//!       pub const Driver = impl.KvsDriver;
//!       pub const meta = .{ .id = "kvs.main" };
//!   };
//!   const Kvs = hal.kvs.from(kvs_spec);

const std = @import("std");
const idf = @import("idf");
const hal = @import("hal");

/// NVS key length limit (15 characters max)
const max_key_len = 15;

/// NVS string value length limit (4000 bytes max, we use a reasonable subset)
/// Note: Using stack buffer to avoid heap allocation. For larger values,
/// consider using blob API or heap allocation.
const max_value_len = 1024;

/// Convert a slice to null-terminated string in provided buffer
fn toNullTerminated(comptime buf_len: usize, buf: *[buf_len]u8, slice: []const u8) hal.kvs.KvsError![:0]const u8 {
    if (slice.len >= buf_len) return error.InvalidKey;
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return buf[0..slice.len :0];
}

/// KVS Driver that implements hal.kvs.Driver interface
pub const KvsDriver = struct {
    const Self = @This();

    nvs: idf.Nvs,

    /// Initialize KVS driver with namespace
    pub fn init(namespace: [:0]const u8) !Self {
        try idf.nvs.init();
        const nvs = try idf.Nvs.open(namespace);
        return .{ .nvs = nvs };
    }

    /// Deinitialize KVS driver
    pub fn deinit(self: *Self) void {
        self.nvs.close();
    }

    /// Get unsigned 32-bit integer (required by hal.kvs)
    pub fn getU32(self: *Self, key: []const u8) hal.kvs.KvsError!u32 {
        var key_buf: [max_key_len + 1]u8 = undefined;
        const key_z = try toNullTerminated(max_key_len + 1, &key_buf, key);

        return self.nvs.getU32(key_z) catch |err| switch (err) {
            idf.nvs.NvsError.NotFound => error.NotFound,
            else => error.ReadError,
        };
    }

    /// Set unsigned 32-bit integer (required by hal.kvs)
    pub fn setU32(self: *Self, key: []const u8, value: u32) hal.kvs.KvsError!void {
        var key_buf: [max_key_len + 1]u8 = undefined;
        const key_z = try toNullTerminated(max_key_len + 1, &key_buf, key);

        self.nvs.setU32(key_z, value) catch return error.WriteError;
    }

    /// Get string (required by hal.kvs)
    pub fn getString(self: *Self, key: []const u8, buf: []u8) hal.kvs.KvsError![]const u8 {
        var key_buf: [max_key_len + 1]u8 = undefined;
        const key_z = try toNullTerminated(max_key_len + 1, &key_buf, key);

        return self.nvs.getString(key_z, buf) catch |err| switch (err) {
            idf.nvs.NvsError.NotFound => error.NotFound,
            idf.nvs.NvsError.InvalidLength => error.BufferTooSmall,
            else => error.ReadError,
        };
    }

    /// Set string (required by hal.kvs)
    /// Note: Maximum value length is 1024 bytes (stack buffer limit).
    /// For larger values, use blob API.
    pub fn setString(self: *Self, key: []const u8, value: []const u8) hal.kvs.KvsError!void {
        var key_buf: [max_key_len + 1]u8 = undefined;
        const key_z = try toNullTerminated(max_key_len + 1, &key_buf, key);

        // Need null-terminated value for NVS
        var val_buf: [max_value_len + 1]u8 = undefined;
        if (value.len > max_value_len) return error.BufferTooSmall;
        @memcpy(val_buf[0..value.len], value);
        val_buf[value.len] = 0;
        const val_z: [:0]const u8 = val_buf[0..value.len :0];

        self.nvs.setString(key_z, val_z) catch return error.WriteError;
    }

    /// Commit changes (required by hal.kvs)
    pub fn commit(self: *Self) hal.kvs.KvsError!void {
        self.nvs.commit() catch return error.WriteError;
    }

    /// Erase key (optional for hal.kvs)
    pub fn erase(self: *Self, key: []const u8) hal.kvs.KvsError!void {
        var key_buf: [max_key_len + 1]u8 = undefined;
        const key_z = try toNullTerminated(max_key_len + 1, &key_buf, key);

        self.nvs.eraseKey(key_z) catch return error.WriteError;
    }

    /// Erase all keys (optional for hal.kvs)
    pub fn eraseAll(self: *Self) hal.kvs.KvsError!void {
        self.nvs.eraseAll() catch return error.WriteError;
    }
};
