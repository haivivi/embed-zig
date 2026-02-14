//! WebSim WASM entry point for nvs_storage
//!
//! Cooperative version: KVS operations in init(), periodic heartbeat in step().

const hal = @import("hal");
const websim = @import("websim");
const platform = @import("platform.zig");

const Board = platform.Board;
const log = websim.sal.log;

var board: Board = undefined;
var initialized: bool = false;
var boot_count: u32 = 0;
var heartbeat_count: u32 = 0;
var last_heartbeat_ms: u64 = 0;
const HEARTBEAT_INTERVAL_MS: u64 = 10000;

pub fn init() void {
    board.init() catch {
        log.err("Board init failed", .{});
        return;
    };
    initialized = true;

    log.info("==========================================", .{});
    log.info("NVS Storage Example - WebSim", .{});
    log.info("==========================================", .{});

    // ===== Boot Counter (u32) =====
    log.info("=== Boot Counter ===", .{});

    boot_count = board.kvs.getU32("boot_count") catch |err| blk: {
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
    log.info("=== Device Name ===", .{});

    var name_buf: [64]u8 = undefined;
    const device_name = board.kvs.getString("device_name", &name_buf) catch |err| blk: {
        if (err == hal.kvs.KvsError.NotFound) {
            log.info("device_name not found, setting default", .{});
            board.kvs.setString("device_name", "WebSim-Zig-Device") catch |e| {
                log.err("Failed to write device_name: {}", .{e});
            };
            break :blk "WebSim-Zig-Device";
        }
        log.err("Failed to read device_name: {}", .{err});
        break :blk "unknown";
    };
    log.info("Device name: {s}", .{device_name});

    // ===== Commit =====
    board.kvs.commit() catch |err| {
        log.err("Failed to commit KVS: {}", .{err});
    };
    log.info("KVS committed (in-memory, no persistence in WebSim)", .{});

    // ===== Summary =====
    log.info("=== Summary ===", .{});
    log.info("Boot count: {} (resets on page reload)", .{boot_count});
    log.info("Device name: {s}", .{device_name});
}

pub fn step() void {
    if (!initialized) return;

    const now = board.uptime();
    if (now - last_heartbeat_ms >= HEARTBEAT_INTERVAL_MS) {
        last_heartbeat_ms = now;
        heartbeat_count += 1;
        log.info("Still running... boot_count={} heartbeat={}", .{ boot_count, heartbeat_count });
    }
}

comptime {
    websim.wasm.exportAll(@This());
}
