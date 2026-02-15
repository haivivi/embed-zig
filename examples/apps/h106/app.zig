//! H106 Demo — Platform Glue
//!
//! Loads assets via board.fs (VFS), connects UI logic with hardware.

const ui = @import("ui.zig");
const assets = @import("assets.zig");
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

// Asset buffers — loaded once at init via VFS
var bg_buf: [120 * 1024]u8 = undefined;
var ultraman_buf: [120 * 1024]u8 = undefined;
var menu_bufs: [5][52 * 1024]u8 = undefined;
var font_buf: [2300 * 1024]u8 = undefined; // TTF font ~2.2MB

pub fn init() void {
    Board.log.info("H106 Demo starting", .{});
    board.init() catch { Board.log.err("Board init failed", .{}); return; };

    // Display
    sim_spi = websim.SimSpi.init(&sim_dc);
    disp = Display.init(&sim_spi, &sim_dc);

    // Load assets from VFS
    Board.log.info("Loading assets via VFS...", .{});
    const bg_img = assets.loadImageFromFs(&board.fs, assets.PATH_BG, &bg_buf);
    const ultraman_img = assets.loadImageFromFs(&board.fs, assets.PATH_ULTRAMAN, &ultraman_buf);

    var menu_imgs: [5]?state_lib.Image = undefined;
    for (0..5) |i| {
        menu_imgs[i] = assets.loadImageFromFs(&board.fs, assets.PATH_MENU_ITEMS[i], &menu_bufs[i]);
    }

    if (bg_img == null) {
        Board.log.err("Failed to load background", .{});
        return;
    }

    // Load TTF font via VFS
    var font_data: ?[]const u8 = null;
    {
        var file = board.fs.open(assets.PATH_FONT, .read) orelse {
            Board.log.err("Failed to load font", .{});
            return;
        };
        defer file.close();
        const data = file.readAll(&font_buf);
        if (data.len > 0) font_data = data;
    }
    Board.log.info("Assets loaded", .{});

    // Init UI with loaded assets + font
    ui.initAssets(bg_img.?, ultraman_img, menu_imgs, font_data);

    // Game
    store = ui.Store.init(.{}, ui.reduce);
    framebuf = ui.FB.init(ui.BLACK);

    ready = true;
    Board.log.info("H106 Demo ready. LEFT/RIGHT=navigate OK=select BACK=back", .{});
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
