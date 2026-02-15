//! H106 Demo — Platform Glue

const ui = @import("ui.zig");
const assets = @import("assets.zig");
const state_lib = @import("ui_state");
const hal = @import("hal");
const websim = @import("websim");
const display_pkg = @import("display");

const platform = @import("platform.zig");
const Board = platform.Board;
const Display = platform.Display;

var store: ui.Store = undefined;
var framebuf: ui.FB = undefined;
var board: Board = undefined;
var sim_dc: websim.SimDcPin = .{};
var sim_spi: websim.SimSpi = undefined;
var disp: Display = undefined;
var ready: bool = false;

// Asset buffers
var bg_buf: [180 * 1024]u8 = undefined;
var ultraman_buf: [180 * 1024]u8 = undefined;
var menu_bufs: [5][80 * 1024]u8 = undefined;
var btn_list_buf: [40 * 1024]u8 = undefined;
var game_icon_bufs: [4][4 * 1024]u8 = undefined;
var setting_icon_bufs: [9][4 * 1024]u8 = undefined;
var font_buf: [2300 * 1024]u8 = undefined;

pub fn init() void {
    Board.log.info("H106 Demo starting", .{});
    board.init() catch { Board.log.err("Board init failed", .{}); return; };

    sim_spi = websim.SimSpi.init(&sim_dc);
    disp = Display.init(&sim_spi, &sim_dc);

    Board.log.info("Loading assets...", .{});

    const bg = assets.loadImageFromFs(&board.fs, assets.PATH_BG, &bg_buf);
    const ultra = assets.loadImageFromFs(&board.fs, assets.PATH_ULTRAMAN, &ultraman_buf);

    var menus: [5]?state_lib.Image = undefined;
    for (0..5) |i| menus[i] = assets.loadImageFromFs(&board.fs, assets.PATH_MENU_ITEMS[i], &menu_bufs[i]);

    const btn_list = assets.loadImageFromFs(&board.fs, assets.PATH_BTN_LIST_ITEM, &btn_list_buf);

    var g_icons: [4]?state_lib.Image = undefined;
    for (0..4) |i| g_icons[i] = assets.loadImageFromFs(&board.fs, assets.PATH_GAME_ICONS[i], &game_icon_bufs[i]);

    var s_icons: [9]?state_lib.Image = undefined;
    for (0..9) |i| s_icons[i] = assets.loadImageFromFs(&board.fs, assets.PATH_SETTING_ICONS[i], &setting_icon_bufs[i]);

    if (bg == null) { Board.log.err("Failed to load bg", .{}); return; }

    // Font
    var font_data: ?[]const u8 = null;
    font_load: {
        var file = board.fs.open(assets.PATH_FONT, .read) orelse {
            Board.log.warn("Font not loaded", .{});
            break :font_load;
        };
        defer file.close();
        const data = file.readAll(&font_buf);
        if (data.len > 0) font_data = data;
    }

    Board.log.info("Assets loaded", .{});

    ui.initAssets(bg.?, ultra, menus, btn_list, g_icons, s_icons, font_data);

    store = ui.Store.init(.{}, ui.reduce);
    framebuf = ui.FB.init(ui.BLACK);
    ready = true;
    Board.log.info("H106 ready. RIGHT=menu, OK=select, ESC=back", .{});
}

pub fn step() void {
    if (!ready) return;
    board.buttons.poll();
    while (board.nextEvent()) |event| {
        switch (event) {
            .button => |btn| {
                if (btn.action == .click) {
                    const e: ?ui.AppEvent = switch (btn.id) {
                        .left => .left, .right => .right, .confirm => .confirm,
                        .back => .back, .vol_up => .up, .vol_down => .down,
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
        disp.flush(.{ .x1 = rect.x, .y1 = rect.y, .x2 = rect.x + rect.w - 1, .y2 = rect.y + rect.h - 1 }, @ptrCast(pixels.ptr));
    }
    framebuf.clearDirty();
}
