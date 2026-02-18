//! Tetris LVGL — Platform Glue

const ui_pkg = @import("ui");
const lvgl = @import("lvgl");
const flux = @import("flux");
const hal = @import("hal");
const websim = @import("websim");
const display_pkg = @import("display");

const game = @import("../state/tetris.zig");
const View = @import("ui.zig").View;

const platform = @import("platform.zig");
const Board = platform.Board;
const Display = platform.Display;
const ButtonId = platform.ButtonId;

const Store = flux.Store(game.GameState, game.GameEvent);

var store: Store = undefined;
var view: View = undefined;
var board: Board = undefined;
var sim_dc: websim.SimDcPin = .{};
var sim_spi: websim.SimSpi = undefined;
var display: Display = undefined;
var ui_ctx: ui_pkg.Context(Display) = undefined;
var ready: bool = false;

pub fn init() void {
    Board.log.info("Tetris LVGL starting", .{});

    board.init() catch { Board.log.err("Board init failed", .{}); return; };

    sim_spi = websim.SimSpi.init(&sim_dc);
    display = Display.init(&sim_spi, &sim_dc);
    ui_ctx = ui_pkg.init(Display, &display) catch { Board.log.err("UI init failed", .{}); return; };

    store = Store.init(.{}, game.reduce);
    view = View.create(ui_ctx.screen());

    ready = true;
    Board.log.info("Tetris LVGL ready", .{});
}

pub fn step() void {
    if (!ready) return;

    board.buttons.poll();
    while (board.nextEvent()) |event| {
        switch (event) {
            .button => |btn| {
                if (btn.action == .click) {
                    const e: ?game.GameEvent = switch (btn.id) {
                        .left => .move_left,
                        .right => .move_right,
                        .confirm => .rotate,
                        .vol_down => .soft_drop,
                        .vol_up => .hard_drop,
                        .back => .restart,
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
        view.sync(store.getState());
        store.commitFrame();
    }

    ui_ctx.tick(16);
    _ = ui_ctx.handler();
}
