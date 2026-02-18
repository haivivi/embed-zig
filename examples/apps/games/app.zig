//! Games — Platform Glue

const state_mod = @import("state/app.zig");
const render_mod = @import("render/render.zig");
const ui_state = @import("ui_state");
const hal = @import("hal");
const websim = @import("websim");
const display_pkg = @import("display");

const platform = @import("platform.zig");
const Board = platform.Board;
const Display = platform.Display;
const ButtonId = platform.ButtonId;

var store: render_mod.Store = undefined;
var framebuf: render_mod.FB = undefined;
var board: Board = undefined;
var sim_dc: websim.SimDcPin = .{};
var sim_spi: websim.SimSpi = undefined;
var disp: Display = undefined;
var ready: bool = false;
var first_frame: bool = true;

pub fn init() void {
    Board.log.info("Games starting", .{});
    board.init() catch { Board.log.err("Board init failed", .{}); return; };

    sim_spi = websim.SimSpi.init(&sim_dc);
    disp = Display.init(&sim_spi, &sim_dc);

    store = render_mod.Store.init(.{}, state_mod.reduce);
    framebuf = render_mod.FB.init(0);
    ready = true;
    Board.log.info("Games ready", .{});
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
                    const e: ?state_mod.AppEvent = switch (btn.id) {
                        .left => .left,
                        .right => .right,
                        .confirm => .confirm,
                        .back => .back,
                        .vol_up => if (store.getState().page == .playing) .{ .game_tetris = .hard_drop } else null,
                        .vol_down => if (store.getState().page == .playing) .{ .game_tetris = .soft_drop } else null,
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
        if (first_frame) {
            render_mod.renderFull(&framebuf, store.getState());
            first_frame = false;
        } else {
            render_mod.render(&framebuf, store.getState(), store.getPrev());
        }
        flushDirty();
        store.commitFrame();
    }
}

fn flushDirty() void {
    var tmp: [240 * 240]u16 = undefined;
    for (framebuf.getDirtyRects()) |rect| {
        const pixels = framebuf.getRegion(rect, &tmp);
        if (pixels.len == 0) continue;
        disp.flush(.{ .x1 = rect.x, .y1 = rect.y, .x2 = rect.x + rect.w - 1, .y2 = rect.y + rect.h - 1 }, @ptrCast(pixels.ptr));
    }
    framebuf.clearDirty();
}
