//! BK7258 CP Base Template
//!
//! Default CP entry point: boots AP, logs readiness, idles.
//! Most apps use this. For custom CP code (e.g. BLE controller),
//! create your own .zig file with `export fn zig_cp_main()`.

const bk = @import("bk");
const armino = bk.armino;

/// CP entry point — called from cp_main.c after bk_init() + boot AP.
export fn zig_cp_main() void {
    armino.log.info("ZIG_CP", "CP core ready (base template)");

    // Idle — FreeRTOS tasks must not return
    while (true) {
        armino.time.sleepMs(60000);
    }
}
