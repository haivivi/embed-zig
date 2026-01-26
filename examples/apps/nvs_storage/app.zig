//! NVS Storage Application - Platform Independent
//!
//! Demonstrates Key-Value Store operations:
//! - Integer read/write (boot counter)
//! - String read/write (device name)
//! - Blob read/write (binary data)
//! - Data persistence across reboots

const platform = @import("platform");
const hal = @import("hal");
const sal = platform.sal;

const Board = hal.Board(platform.spec);

pub fn run() void {
    sal.log.info("==========================================", .{});
    sal.log.info("NVS Storage Example - HAL", .{});
    sal.log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        sal.log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    sal.log.info("Board initialized", .{});

    // ===== Boot Counter (u32) =====
    sal.log.info("", .{});
    sal.log.info("=== Boot Counter ===", .{});

    var boot_count: u32 = board.kvs.getU32("boot_count") catch |err| blk: {
        if (err == hal.kvs.KvsError.NotFound) {
            sal.log.info("boot_count not found, starting from 0", .{});
            break :blk 0;
        }
        sal.log.err("Failed to read boot_count: {}", .{err});
        break :blk 0;
    };

    boot_count += 1;
    sal.log.info("Boot count: {}", .{boot_count});

    board.kvs.setU32("boot_count", boot_count) catch |err| {
        sal.log.err("Failed to write boot_count: {}", .{err});
    };

    // ===== Device Name (String) =====
    sal.log.info("", .{});
    sal.log.info("=== Device Name ===", .{});

    var name_buf: [64]u8 = undefined;
    const device_name = board.kvs.getString("device_name", &name_buf) catch |err| blk: {
        if (err == hal.kvs.KvsError.NotFound) {
            sal.log.info("device_name not found, setting default", .{});
            board.kvs.setString("device_name", "ESP32-Zig-Device") catch |e| {
                sal.log.err("Failed to write device_name: {}", .{e});
            };
            break :blk "ESP32-Zig-Device";
        }
        sal.log.err("Failed to read device_name: {}", .{err});
        break :blk "unknown";
    };
    sal.log.info("Device name: {s}", .{device_name});

    // ===== Commit Changes =====
    board.kvs.commit() catch |err| {
        sal.log.err("Failed to commit KVS: {}", .{err});
    };
    sal.log.info("KVS committed to flash", .{});

    // ===== Summary =====
    sal.log.info("", .{});
    sal.log.info("=== Summary ===", .{});
    sal.log.info("Boot count: {} (will increment on next boot)", .{boot_count});
    sal.log.info("Device name: {s}", .{device_name});
    sal.log.info("", .{});
    sal.log.info("Reboot the device to see boot_count increment!", .{});

    // Keep running
    while (true) {
        sal.sleepMs(10000);
        sal.log.info("Still running... boot_count={}", .{boot_count});
    }
}
