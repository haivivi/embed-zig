//! BK7258 Platform — Minimal Zig entry for Armino SDK
//!
//! Exports `zig_main()` callable from C. Uses C helper for logging
//! since BK_LOGI is a variadic C macro.

const c = struct {
    // Thin C helpers (defined in bk_zig_helper.c)
    extern fn bk_zig_log(tag: [*:0]const u8, msg: [*:0]const u8) void;
    extern fn bk_zig_log_int(tag: [*:0]const u8, msg: [*:0]const u8, val: i32) void;
    extern fn bk_zig_delay_ms(ms: u32) void;
};

const TAG = "ZIG";

fn log(msg: [*:0]const u8) void {
    c.bk_zig_log(TAG, msg);
}

fn logInt(msg: [*:0]const u8, val: i32) void {
    c.bk_zig_log_int(TAG, msg, val);
}

fn delayMs(ms: u32) void {
    c.bk_zig_delay_ms(ms);
}

/// Called from Armino C code after bk_init().
export fn zig_main() void {
    log("========================================");
    log("=== Hello from Zig on BK7258!        ===");
    log("========================================");

    var count: i32 = 0;
    while (true) {
        logInt("Zig alive count=", count);
        count += 1;
        delayMs(3000);
    }
}
