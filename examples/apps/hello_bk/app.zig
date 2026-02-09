//! Hello BK7258 — Minimal Bazel-native BK example
//!
//! Tests the full pipeline: Bazel → Zig → ARM .o → Armino → flash

const bk = @import("bk");
const armino = bk.armino;
const board = bk.boards.bk7258;

/// Zig entry point — called from Armino cp_main.c
export fn zig_main() void {
    armino.log.info("ZIG", "========================================");
    armino.log.info("ZIG", "=== Hello BK7258 (Bazel-native)      ===");
    armino.log.info("ZIG", "========================================");

    armino.log.logFmt("ZIG", "Board: {s}", .{board.name});
    armino.log.logFmt("ZIG", "Boot time: {}ms", .{armino.time.nowMs()});

    var count: i32 = 0;
    while (true) {
        armino.log.logFmt("ZIG", "alive count={} uptime={}ms", .{ count, armino.time.nowMs() });
        count += 1;
        armino.time.sleepMs(3000);
    }
}
