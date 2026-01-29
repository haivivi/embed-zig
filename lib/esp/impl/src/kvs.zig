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
        // Need null-terminated key for NVS
        var key_buf: [16]u8 = undefined;
        if (key.len >= key_buf.len) return error.InvalidKey;
        @memcpy(key_buf[0..key.len], key);
        key_buf[key.len] = 0;
        const key_z: [:0]const u8 = key_buf[0..key.len :0];

        return self.nvs.getU32(key_z) catch |err| switch (err) {
            idf.nvs.NvsError.NotFound => error.NotFound,
            else => error.ReadError,
        };
    }

    /// Set unsigned 32-bit integer (required by hal.kvs)
    pub fn setU32(self: *Self, key: []const u8, value: u32) hal.kvs.KvsError!void {
        var key_buf: [16]u8 = undefined;
        if (key.len >= key_buf.len) return error.InvalidKey;
        @memcpy(key_buf[0..key.len], key);
        key_buf[key.len] = 0;
        const key_z: [:0]const u8 = key_buf[0..key.len :0];

        self.nvs.setU32(key_z, value) catch return error.WriteError;
    }

    /// Get string (required by hal.kvs)
    pub fn getString(self: *Self, key: []const u8, buf: []u8) hal.kvs.KvsError![]const u8 {
        var key_buf: [16]u8 = undefined;
        if (key.len >= key_buf.len) return error.InvalidKey;
        @memcpy(key_buf[0..key.len], key);
        key_buf[key.len] = 0;
        const key_z: [:0]const u8 = key_buf[0..key.len :0];

        return self.nvs.getString(key_z, buf) catch |err| switch (err) {
            idf.nvs.NvsError.NotFound => error.NotFound,
            idf.nvs.NvsError.InvalidLength => error.BufferTooSmall,
            else => error.ReadError,
        };
    }

    /// Set string (required by hal.kvs)
    pub fn setString(self: *Self, key: []const u8, value: []const u8) hal.kvs.KvsError!void {
        var key_buf: [16]u8 = undefined;
        if (key.len >= key_buf.len) return error.InvalidKey;
        @memcpy(key_buf[0..key.len], key);
        key_buf[key.len] = 0;
        const key_z: [:0]const u8 = key_buf[0..key.len :0];

        // Need null-terminated value for NVS
        var val_buf: [256]u8 = undefined;
        if (value.len >= val_buf.len) return error.StorageFull;
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
        var key_buf: [16]u8 = undefined;
        if (key.len >= key_buf.len) return error.InvalidKey;
        @memcpy(key_buf[0..key.len], key);
        key_buf[key.len] = 0;
        const key_z: [:0]const u8 = key_buf[0..key.len :0];

        self.nvs.eraseKey(key_z) catch return error.WriteError;
    }

    /// Erase all keys (optional for hal.kvs)
    pub fn eraseAll(self: *Self) hal.kvs.KvsError!void {
        self.nvs.eraseAll() catch return error.WriteError;
    }
};
