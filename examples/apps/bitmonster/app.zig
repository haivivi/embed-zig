//! BitMonster — Platform Glue

const state_mod = @import("state.zig");
const ui = @import("ui.zig");
const flux = @import("flux");
const hal = @import("hal");
const websim = @import("websim");

const platform = @import("platform.zig");
const Board = platform.Board;
const Display = platform.Display;

const Store = flux.Store(state_mod.AppState, state_mod.Event);

var store: Store = undefined;
var framebuf: ui.FB = undefined;
var board: Board = undefined;
var sim_dc: websim.SimDcPin = .{};
var sim_spi: websim.SimSpi = undefined;
var disp: Display = undefined;
var ready: bool = false;
var prev_state: state_mod.AppState = .{};

var first_frame: bool = true;
var flush_tmp: [320 * 320]u16 = undefined;

pub fn init() void {
    Board.log.info("BitMonster starting", .{});
    board.init() catch { Board.log.err("Board init failed", .{}); return; };

    sim_spi = websim.SimSpi.init(&sim_dc);
    disp = Display.init(&sim_spi, &sim_dc);

    store = Store.init(.{}, state_mod.reduce);
    framebuf = ui.FB.init(0);
    prev_state = store.getState().*;
    ready = true;
    Board.log.info("BitMonster ready", .{});
}

pub fn step() void {
    if (!ready) return;
    board.buttons.poll();
    const t = board.uptime();
    _ = board.button.poll(t);

    while (board.nextEvent()) |event| {
        switch (event) {
            .button => |btn| {
                if (btn.action == .click) {
                    const e: ?state_mod.Event = switch (btn.id) {
                        .up => .up,
                        .down => .down,
                        .left => .left,
                        .right => .right,
                        .back => .back,
                        .confirm => .confirm,
                    };
                    if (e) |ev| store.dispatch(ev);
                }
            },
            else => {},
        }
    }

    store.dispatch(.tick);

    if (store.isDirty()) {
        const prev = if (first_frame) null else &prev_state;
        ui.render(&framebuf, store.getState(), prev);
        flushDisplay();
        prev_state = store.getState().*;
        store.commitFrame();
        first_frame = false;
    }
}

fn flushDisplay() void {
    for (framebuf.getDirtyRects()) |rect| {
        const pixels = framebuf.getRegion(rect, &flush_tmp);
        if (pixels.len == 0) continue;
        disp.flush(.{
            .x1 = rect.x,
            .y1 = rect.y,
            .x2 = rect.x + rect.w - 1,
            .y2 = rect.y + rect.h - 1,
        }, @ptrCast(pixels.ptr));
    }
    framebuf.clearDirty();
}
