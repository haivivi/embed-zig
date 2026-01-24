//! NVS Storage Example - Zig Version
//!
//! Demonstrates NVS (Non-Volatile Storage) operations:
//! - Integer read/write (boot counter)
//! - String read/write (device name)
//! - Blob read/write (binary data)
//! - Data persistence across reboots

const std = @import("std");
const idf = @import("idf");

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = idf.log.stdLogFn,
};

const NAMESPACE = "storage";

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("NVS Storage Example - Zig Version", .{});
    std.log.info("==========================================", .{});

    // Initialize NVS
    idf.nvs.init() catch |err| {
        std.log.err("Failed to initialize NVS: {}", .{err});
        return;
    };
    std.log.info("NVS initialized", .{});

    // Open NVS namespace
    var nvs = idf.Nvs.open(NAMESPACE) catch |err| {
        std.log.err("Failed to open NVS namespace: {}", .{err});
        return;
    };
    defer nvs.close();

    // ===== Boot Counter (u32) =====
    std.log.info("", .{});
    std.log.info("=== Boot Counter ===", .{});

    var boot_count: u32 = nvs.getU32("boot_count") catch |err| blk: {
        if (err == idf.nvs.NvsError.NotFound) {
            std.log.info("boot_count not found, starting from 0", .{});
            break :blk 0;
        }
        std.log.err("Failed to read boot_count: {}", .{err});
        break :blk 0;
    };

    boot_count += 1;
    std.log.info("Boot count: {}", .{boot_count});

    nvs.setU32("boot_count", boot_count) catch |err| {
        std.log.err("Failed to write boot_count: {}", .{err});
    };

    // ===== Device Name (String) =====
    std.log.info("", .{});
    std.log.info("=== Device Name ===", .{});

    var name_buf: [64]u8 = undefined;
    const device_name = nvs.getString("device_name", &name_buf) catch |err| blk: {
        if (err == idf.nvs.NvsError.NotFound) {
            std.log.info("device_name not found, setting default", .{});
            nvs.setString("device_name", "ESP32-Zig-Device") catch |e| {
                std.log.err("Failed to write device_name: {}", .{e});
            };
            break :blk "ESP32-Zig-Device";
        }
        std.log.err("Failed to read device_name: {}", .{err});
        break :blk "unknown";
    };
    std.log.info("Device name: {s}", .{device_name});

    // ===== Blob (Binary Data) =====
    std.log.info("", .{});
    std.log.info("=== Blob Data ===", .{});

    // Store some binary data
    const test_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE };
    nvs.setBlob("test_blob", &test_data) catch |err| {
        std.log.err("Failed to write blob: {}", .{err});
    };

    // Read it back
    var blob_buf: [16]u8 = undefined;
    const blob = nvs.getBlob("test_blob", &blob_buf) catch |err| blk: {
        std.log.err("Failed to read blob: {}", .{err});
        break :blk &[_]u8{};
    };
    std.log.info("Blob data ({} bytes): {x}", .{ blob.len, blob });

    // ===== Commit Changes =====
    nvs.commit() catch |err| {
        std.log.err("Failed to commit NVS: {}", .{err});
    };
    std.log.info("NVS committed to flash", .{});

    // ===== Summary =====
    std.log.info("", .{});
    std.log.info("=== Summary ===", .{});
    std.log.info("Boot count: {} (will increment on next boot)", .{boot_count});
    std.log.info("Device name: {s}", .{device_name});
    std.log.info("Blob stored: {} bytes", .{blob.len});
    std.log.info("", .{});
    std.log.info("Reboot the device to see boot_count increment!", .{});

    // Keep running
    while (true) {
        idf.delayMs(10000);
        std.log.info("Still running... boot_count={}", .{boot_count});
    }
}
