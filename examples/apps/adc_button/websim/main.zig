//! Native WebSim entry point for adc_button
//!
//! Same app logic as wasm_main.zig, but runs natively with a webview window.
//! Cannot import wasm_main.zig directly (it has comptime WASM exports).

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
    log.info("ADC Button Example - WebSim Native", .{});
    log.info("Board: {s}", .{Board.meta.id});
    log.info("==========================================", .{});
    log.info("Ready! Press ADC buttons...", .{});
}

pub fn step() void {
    if (!initialized) return;

    board.buttons.poll();

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

    step_count += 1;
    if (step_count >= DEBUG_INTERVAL) {
        step_count = 0;
        const raw = board.buttons.getLastRaw();
        log.info("[DEBUG] raw={} uptime={}ms", .{ raw, board.uptime() });
    }
}

const html = @embedFile("native_shell.html");

pub fn main() !void {
    websim.native.run(@This(), html);
}
