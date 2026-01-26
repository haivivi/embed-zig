//! ADC Button Example - Platform Independent App
//!
//! Demonstrates ADC button group with HAL.
//! Hardware: ESP32-S3-Korvo-2 V3 with 6 ADC buttons

const hal = @import("hal");

const platform = @import("platform.zig");
const Board = platform.Board;
const Hardware = platform.Hardware;
const ButtonId = platform.ButtonId;
const sal = platform.sal;
const log = sal.log;

const BUILD_TAG = "adc_button_hal_v5";

fn printBoardInfo() void {
    log.info("==========================================", .{});
    log.info("ADC Button Example - HAL v5", .{});
    log.info("Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});
    log.info("Board:       {s}", .{Hardware.name});
    log.info("ADC Channel: {}", .{@intFromEnum(Hardware.adc_channel)});
    log.info("Buttons:     6 (auto-managed)", .{});
    log.info("==========================================", .{});
}

pub fn run() void {
    printBoardInfo();

    // Initialize board
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Failed to initialize board: {}", .{err});
        return;
    };
    defer board.deinit();

    log.info("Board initialized", .{});
    log.info("Ready! Press ADC buttons...", .{});
    log.info("==========================================", .{});

    // Main event loop
    var loop_count: u32 = 0;
    const LOG_INTERVAL = 500;

    while (true) {
        // Poll - HAL handles everything
        board.poll();

        // Process events
        while (board.nextEvent()) |event| {
            switch (event) {
                .button => |btn| {
                    const btn_name = btn.id.name();

                    switch (btn.action) {
                        .press => {
                            const raw = board.buttons.getLastRaw();
                            log.info("[{s}] {s} PRESSED (raw={})", .{ btn.source, btn_name, raw });
                        },
                        .release => {
                            log.info("[{s}] {s} RELEASED (held {}ms)", .{ btn.source, btn_name, btn.duration_ms });
                        },
                        .click => {
                            log.info("[{s}] {s} CLICK", .{ btn.source, btn_name });
                        },
                        .double_click => {
                            log.info("[{s}] {s} DOUBLE-CLICK", .{ btn.source, btn_name });
                        },
                        .long_press => {
                            log.info("[{s}] {s} LONG-PRESS ({}ms)", .{ btn.source, btn_name, btn.duration_ms });
                        },
                    }
                },
                .system => |sys| {
                    log.info("[System] {s}", .{@tagName(sys)});
                },
                .timer => |t| {
                    log.info("[Timer] id={}", .{t.id});
                },
                .wifi => {},
            }
        }

        // Periodic debug output
        loop_count += 1;
        if (loop_count >= LOG_INTERVAL) {
            loop_count = 0;
            const raw = board.buttons.getLastRaw();
            log.info("[DEBUG] raw={} uptime={}ms", .{ raw, board.uptime() });
        }

        sal.sleepMs(10);
    }
}
