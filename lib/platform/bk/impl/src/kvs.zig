//! KVS Implementation for BK7258 — hal.kvs.Driver compatible
//!
//! Uses EasyFlash V4 via armino.kvs binding.
//! Error types match hal.kvs.KvsError exactly.

const armino = @import("../../armino/src/armino.zig");

const KvsError = error{
    NotFound,
    BufferTooSmall,
    InvalidKey,
    StorageFull,
    WriteError,
    ReadError,
};

pub const KvsDriver = struct {
    const Self = @This();

    initialized: bool = false,

    pub fn init() !Self {
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        self.initialized = false;
    }

    pub fn getU32(_: *Self, key: []const u8) KvsError!u32 {
        var buf: [4]u8 = undefined;
        const len = armino.kvs.get(key, &buf) catch return error.NotFound;
        if (len != 4) return error.NotFound;
        return @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) | (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24);
    }

    pub fn setU32(_: *Self, key: []const u8, value: u32) KvsError!void {
        const buf = [4]u8{
            @truncate(value),
            @truncate(value >> 8),
            @truncate(value >> 16),
            @truncate(value >> 24),
        };
        armino.kvs.set(key, &buf) catch return error.WriteError;
    }

    pub fn getString(_: *Self, key: []const u8, buf: []u8) KvsError![]const u8 {
        const len = armino.kvs.get(key, buf) catch return error.NotFound;
        return buf[0..len];
    }

    pub fn setString(_: *Self, key: []const u8, value: []const u8) KvsError!void {
        armino.kvs.set(key, value) catch return error.WriteError;
    }

    pub fn commit(_: *Self) KvsError!void {
        armino.kvs.commit() catch return error.WriteError;
    }

    pub fn erase(_: *Self, key: []const u8) KvsError!void {
        armino.kvs.set(key, &[0]u8{}) catch return error.WriteError;
    }
};
