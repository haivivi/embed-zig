//! ESP32-S3-DevKitC-1 Board Support Package
//!
//! NVS storage configuration for the ESP32-S3 DevKit.

const std = @import("std");
const hal = @import("hal");
const idf = @import("esp");

// ============================================================================
// Platform SAL
// ============================================================================

pub const sal = idf.sal;

// ============================================================================
// RTC Driver (required by hal.Board)
// ============================================================================

pub const RtcDriver = struct {
    pub fn init() !RtcDriver {
        return .{};
    }

    pub fn deinit(_: *RtcDriver) void {}

    pub fn uptime(_: *RtcDriver) u64 {
        return idf.nowMs();
    }

    pub fn read(_: *RtcDriver) ?i64 {
        return null; // No RTC hardware, return null
    }
};

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = hal.Meta{ .id = "rtc.esp32s3" };
};

// ============================================================================
// KVS Driver (NVS-based)
// ============================================================================

pub const KvsDriver = struct {
    nvs: idf.Nvs,

    // Buffer for null-terminating keys
    key_buf: [64]u8 = undefined,
    // Buffer for null-terminating string values
    value_buf: [256]u8 = undefined,

    pub fn init() !KvsDriver {
        // Initialize NVS flash
        idf.nvs.init() catch |err| {
            std.log.err("Failed to init NVS flash: {}", .{err});
            return err;
        };

        // Open NVS namespace
        const nvs = idf.Nvs.open("storage") catch |err| {
            std.log.err("Failed to open NVS namespace: {}", .{err});
            return err;
        };

        std.log.info("DevKit KvsDriver: NVS initialized", .{});
        return .{ .nvs = nvs };
    }

    pub fn deinit(self: *KvsDriver) void {
        self.nvs.close();
    }

    // Helper to convert key to null-terminated string
    fn toNullTerminated(self: *KvsDriver, key: []const u8) [:0]const u8 {
        const len = @min(key.len, self.key_buf.len - 1);
        @memcpy(self.key_buf[0..len], key[0..len]);
        self.key_buf[len] = 0;
        return self.key_buf[0..len :0];
    }

    pub fn getU32(self: *KvsDriver, key: []const u8) !u32 {
        const key_z = self.toNullTerminated(key);
        return self.nvs.getU32(key_z) catch |err| {
            return switch (err) {
                idf.nvs.NvsError.NotFound => hal.kvs.KvsError.NotFound,
                else => hal.kvs.KvsError.ReadError,
            };
        };
    }

    pub fn setU32(self: *KvsDriver, key: []const u8, value: u32) !void {
        const key_z = self.toNullTerminated(key);
        self.nvs.setU32(key_z, value) catch {
            return hal.kvs.KvsError.WriteError;
        };
    }

    pub fn getString(self: *KvsDriver, key: []const u8, buf: []u8) ![]const u8 {
        const key_z = self.toNullTerminated(key);
        return self.nvs.getString(key_z, buf) catch |err| {
            return switch (err) {
                idf.nvs.NvsError.NotFound => hal.kvs.KvsError.NotFound,
                idf.nvs.NvsError.InvalidLength => hal.kvs.KvsError.BufferTooSmall,
                else => hal.kvs.KvsError.ReadError,
            };
        };
    }

    fn valueToNullTerminated(self: *KvsDriver, value: []const u8) [:0]const u8 {
        const len = @min(value.len, self.value_buf.len - 1);
        @memcpy(self.value_buf[0..len], value[0..len]);
        self.value_buf[len] = 0;
        return self.value_buf[0..len :0];
    }

    pub fn setString(self: *KvsDriver, key: []const u8, value: []const u8) !void {
        const key_z = self.toNullTerminated(key);
        const value_z = self.valueToNullTerminated(value);
        self.nvs.setString(key_z, value_z) catch {
            return hal.kvs.KvsError.WriteError;
        };
    }

    pub fn getBlob(self: *KvsDriver, key: []const u8, buf: []u8) ![]const u8 {
        const key_z = self.toNullTerminated(key);
        return self.nvs.getBlob(key_z, buf) catch |err| {
            return switch (err) {
                idf.nvs.NvsError.NotFound => hal.kvs.KvsError.NotFound,
                idf.nvs.NvsError.InvalidLength => hal.kvs.KvsError.BufferTooSmall,
                else => hal.kvs.KvsError.ReadError,
            };
        };
    }

    pub fn setBlob(self: *KvsDriver, key: []const u8, data: []const u8) !void {
        const key_z = self.toNullTerminated(key);
        self.nvs.setBlob(key_z, data) catch {
            return hal.kvs.KvsError.WriteError;
        };
    }

    pub fn commit(self: *KvsDriver) !void {
        self.nvs.commit() catch {
            return hal.kvs.KvsError.WriteError;
        };
    }
};

pub const kvs_spec = struct {
    pub const Driver = KvsDriver;
    pub const meta = hal.Meta{ .id = "kvs.nvs" };
};
