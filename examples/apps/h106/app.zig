//! H106 Demo — Platform Glue

const ui = @import("ui.zig");
const state_lib = @import("ui_state");
const hal = @import("hal");
const websim = @import("websim");
const display_pkg = @import("display");

const platform = @import("platform.zig");
const Board = platform.Board;
const Display = platform.Display;
const ButtonId = platform.ButtonId;

var store: ui.Store = undefined;
var framebuf: ui.FB = undefined;
var board: Board = undefined;
var sim_dc: websim.SimDcPin = .{};
var sim_spi: websim.SimSpi = undefined;
var disp: Display = undefined;
var ready: bool = false;

pub fn init() void {
    Board.log.info("H106 Demo starting", .{});
    board.init() catch { Board.log.err("Board init failed", .{}); return; };
    sim_spi = websim.SimSpi.init(&sim_dc);
    disp = Display.init(&sim_spi, &sim_dc);
    store = ui.Store.init(.{}, ui.reduce);
    framebuf = ui.FB.init(ui.BLACK);
    ready = true;
    Board.log.info("H106 Demo ready", .{});
}

pub fn step() void {
    if (!ready) return;

    board.buttons.poll();
    while (board.nextEvent()) |event| {
        switch (event) {
            .button => |btn| {
                if (btn.action == .click) {
                    const e: ?ui.AppEvent = switch (btn.id) {
                        .left => .left,
                        .right => .right,
                        .confirm => .confirm,
                        .back => .back,
                        .vol_up => .up,
                        .vol_down => .down,
                        else => null,
                    };
                    if (e) |ev| store.dispatch(ev);
                }
            },
            else => {},
        }
    }

    store.dispatch(.tick);

    if (store.isDirty()) {
        ui.render(&framebuf, store.getState());
        flushDisplay();
        store.commitFrame();
    }
}

fn flushDisplay() void {
    var tmp: [240 * 240]u16 = undefined;
    for (framebuf.getDirtyRects()) |rect| {
        const pixels = framebuf.getRegion(rect, &tmp);
        if (pixels.len == 0) continue;
        disp.flush(.{
            .x1 = rect.x, .y1 = rect.y,
            .x2 = rect.x + rect.w - 1, .y2 = rect.y + rect.h - 1,
        }, @ptrCast(pixels.ptr));
    }
    framebuf.clearDirty();
}
