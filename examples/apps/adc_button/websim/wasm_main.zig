//! WebSim WASM entry point for adc_button
//!
//! Cooperative version: poll ADC buttons + process events each step.

const hal = @import("hal");
const websim = @import("websim");
const platform = @import("platform.zig");

const Board = platform.Board;
const ButtonId = platform.ButtonId;
const log = websim.sal.log;

var board: Board = undefined;
var initialized: bool = false;
var step_count: u32 = 0;
const DEBUG_INTERVAL: u32 = 500;

pub fn init() void {
    board.init() catch {
        log.err("Board init failed", .{});
        return;
    };
    initialized = true;

    log.info("==========================================", .{});
    log.info("ADC Button Example - WebSim", .{});
    log.info("Board: {s}", .{Board.meta.id});
    log.info("==========================================", .{});
    log.info("Ready! Press ADC buttons...", .{});
}

pub fn step() void {
    if (!initialized) return;

    // Poll button group
    board.buttons.poll();

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
            else => {},
        }
    }

    // Periodic debug output
    step_count += 1;
    if (step_count >= DEBUG_INTERVAL) {
        step_count = 0;
        const raw = board.buttons.getLastRaw();
        log.info("[DEBUG] raw={} uptime={}ms", .{ raw, board.uptime() });
    }
}

pub const board_config_json = websim.boards.korvo2_v3.board_config_json;

comptime {
    websim.wasm.exportAll(@This());
}
