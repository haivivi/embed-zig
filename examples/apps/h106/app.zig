//! H106 Demo — Platform Glue (zero-copy asset loading)

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

// Only the flush tmp buffer needs RAM — everything else is zero-copy from flash
var flush_tmp: [240 * 240]u16 = undefined;

pub fn init() void {
    Board.log.info("H106 Demo starting", .{});
    board.init() catch { Board.log.err("Board init failed", .{}); return; };

    sim_spi = websim.SimSpi.init(&sim_dc);
    disp = Display.init(&sim_spi, &sim_dc);

    Board.log.info("Loading assets (zero-copy)...", .{});

    // All assets loaded zero-copy — no RAM buffers needed.
    // loadImageFromFs uses file.data (mmap) when available.
    var dummy_buf: [8]u8 = undefined; // fallback for non-mmap (unused with EmbedFs)

    const bg = assets.loadImageFromFs(&board.fs, assets.PATH_BG, &dummy_buf);
    const ultra = assets.loadImageFromFs(&board.fs, assets.PATH_ULTRAMAN, &dummy_buf);

    var menus: [5]?state_lib.Image = undefined;
    for (0..5) |i| menus[i] = assets.loadImageFromFs(&board.fs, assets.PATH_MENU_ITEMS[i], &dummy_buf);

    const btn_list = assets.loadImageFromFs(&board.fs, assets.PATH_BTN_LIST_ITEM, &dummy_buf);

    var g_icons: [4]?state_lib.Image = undefined;
    for (0..4) |i| g_icons[i] = assets.loadImageFromFs(&board.fs, assets.PATH_GAME_ICONS[i], &dummy_buf);

    var s_icons: [9]?state_lib.Image = undefined;
    for (0..9) |i| s_icons[i] = assets.loadImageFromFs(&board.fs, assets.PATH_SETTING_ICONS[i], &dummy_buf);

    if (bg == null) { Board.log.err("Failed to load bg", .{}); return; }

    // Font: also zero-copy — TtfFont.init just takes a data slice
    var font_data: ?[]const u8 = null;
    font_load: {
        var file = board.fs.open(assets.PATH_FONT, .read) orelse {
            Board.log.warn("Font not loaded", .{});
            break :font_load;
        };
        defer file.close();
        // Zero-copy: use file.data directly
        if (file.data) |data| {
            font_data = data;
        } else {
            Board.log.warn("Font requires mmap-capable VFS", .{});
        }
    }

    // Startup animation
    var anim_data: ?[]const u8 = null;
    anim_load: {
        var file = board.fs.open(assets.PATH_STARTUP_ANIM, .read) orelse break :anim_load;
        defer file.close();
        if (file.data) |data| anim_data = data;
    }

    Board.log.info("Assets loaded (zero-copy from flash)", .{});

    ui.initStartupAnim(anim_data);
    ui.initAssets(bg.?, ultra, menus, btn_list, g_icons, s_icons, font_data);

    store = ui.Store.init(.{}, ui.reduce);
    framebuf = ui.FB.init(ui.BLACK);
    ready = true;
    Board.log.info("H106 ready. RIGHT=menu, OK=select, ESC=back", .{});
}

var power_was_held: bool = false;

pub fn step() void {
    if (!ready) return;
    board.buttons.poll();

    // Power button: read raw pressed state directly from driver
    // (bypass HAL debounce — we handle hold duration in the reducer)
    const t = board.uptime();
    _ = board.button.poll(t);
    const power_held = board.button.driver.isPressed();
    if (power_held) {
        store.dispatch(.power_hold);
    } else if (power_was_held) {
        store.dispatch(.power_release);
    }
    power_was_held = power_held;

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
    for (framebuf.getDirtyRects()) |rect| {
        const pixels = framebuf.getRegion(rect, &flush_tmp);
        if (pixels.len == 0) continue;
        disp.flush(.{ .x1 = rect.x, .y1 = rect.y, .x2 = rect.x + rect.w - 1, .y2 = rect.y + rect.h - 1 }, @ptrCast(pixels.ptr));
    }
    framebuf.clearDirty();
}
