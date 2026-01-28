//! NVS Storage Application - Platform Independent
//!
//! Demonstrates Key-Value Store operations:
//! - Integer read/write (boot counter)
//! - String read/write (device name)
//! - Blob read/write (binary data)
//! - Data persistence across reboots

const hal = @import("hal");

const platform = @import("platform.zig");

const Board = platform.Board;
const log = Board.log;

pub fn run() void {
    log.info("==========================================", .{});
    log.info("NVS Storage Example - HAL", .{});
    log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    log.info("Board initialized", .{});

    // ===== Boot Counter (u32) =====
    log.info("", .{});
    log.info("=== Boot Counter ===", .{});

    var boot_count: u32 = board.kvs.getU32("boot_count") catch |err| blk: {
        if (err == hal.kvs.KvsError.NotFound) {
            log.info("boot_count not found, starting from 0", .{});
            break :blk 0;
        }
        log.err("Failed to read boot_count: {}", .{err});
        break :blk 0;
    };

    boot_count += 1;
    log.info("Boot count: {}", .{boot_count});

    board.kvs.setU32("boot_count", boot_count) catch |err| {
        log.err("Failed to write boot_count: {}", .{err});
    };

    // ===== Device Name (String) =====
    log.info("", .{});
    log.info("=== Device Name ===", .{});

    var name_buf: [64]u8 = undefined;
    const device_name = board.kvs.getString("device_name", &name_buf) catch |err| blk: {
        if (err == hal.kvs.KvsError.NotFound) {
            log.info("device_name not found, setting default", .{});
            board.kvs.setString("device_name", "ESP32-Zig-Device") catch |e| {
                log.err("Failed to write device_name: {}", .{e});
            };
            break :blk "ESP32-Zig-Device";
        }
        log.err("Failed to read device_name: {}", .{err});
        break :blk "unknown";
    };
    log.info("Device name: {s}", .{device_name});

    // ===== Commit Changes =====
    board.kvs.commit() catch |err| {
        log.err("Failed to commit KVS: {}", .{err});
    };
    log.info("KVS committed to flash", .{});

    // ===== Summary =====
    log.info("", .{});
    log.info("=== Summary ===", .{});
    log.info("Boot count: {} (will increment on next boot)", .{boot_count});
    log.info("Device name: {s}", .{device_name});
    log.info("", .{});
    log.info("Reboot the device to see boot_count increment!", .{});

    // Keep running
    while (true) {
        Board.time.sleepMs(10000);
        log.info("Still running... boot_count={}", .{boot_count});
    }
}
