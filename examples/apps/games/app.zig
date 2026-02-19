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

// Fonts
var font_text_inst: ui_state.TtfFont = undefined;
var font_icon_inst: ui_state.TtfFont = undefined;

pub fn init() void {
    Board.log.info("Games starting", .{});
    board.init() catch { Board.log.err("Board init failed", .{}); return; };

    sim_spi = websim.SimSpi.init(&sim_dc);
    disp = Display.init(&sim_spi, &sim_dc);

    // Load fonts from VFS
    font_load: {
        var file = board.fs.open("/fonts/PressStart2P.ttf", .read) orelse break :font_load;
        defer file.close();
        if (file.data) |data| {
            if (ui_state.TtfFont.init(data, 14.0)) |f| {
                font_text_inst = f;
                render_mod.font_text = &font_text_inst;
            }
        }
        Board.log.info("Text font loaded", .{});
    }
    icon_load: {
        var file = board.fs.open("/fonts/Phosphor-Bold.ttf", .read) orelse break :icon_load;
        defer file.close();
        if (file.data) |data| {
            if (ui_state.TtfFont.init(data, 48.0)) |f| {
                font_icon_inst = f;
                render_mod.font_icon = &font_icon_inst;
            }
        }
        Board.log.info("Icon font loaded", .{});
    }

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
                        .vol_up => if (store.getState().page == .playing) switch (store.getState().current_game) {
                            .tetris => .{ .game_tetris = .hard_drop },
                            .racer => null,
                        } else null,
                        .vol_down => if (store.getState().page == .playing) switch (store.getState().current_game) {
                            .tetris => .{ .game_tetris = .soft_drop },
                            .racer => null,
                        } else null,
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
