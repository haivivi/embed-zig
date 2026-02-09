//! BK7258 Zig Entry Point
//!
//! Exports zig_main() for Armino's cp_main.c to call.
//! Tests the platform layer: log + time on CP core.

const bk = @import("bk.zig");
const armino = bk.armino;

/// Called from Armino C code (cp_main.c) after bk_init().
export fn zig_main() void {
    armino.log.info("ZIG", "========================================");
    armino.log.info("ZIG", "=== BK7258 Platform Layer Test (CP)  ===");
    armino.log.info("ZIG", "========================================");

    // Test formatted log
    armino.log.logFmt("ZIG", "Board: {s}", .{bk.boards.bk7258.name});

    // Test time
    const start = armino.time.nowMs();
    armino.log.logFmt("ZIG", "Boot time: {}ms", .{start});

    // Periodic output
    var count: i32 = 0;
    while (true) {
        const now = armino.time.nowMs();
        armino.log.logFmt("ZIG", "alive count={} uptime={}ms", .{ count, now });
        count += 1;
        armino.time.sleepMs(3000);
    }
}
