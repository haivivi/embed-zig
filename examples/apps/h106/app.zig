//! H106 Demo — Platform Glue (zero global mutable UI state)

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

// Resources — initialized once, immutable after init
var res: ui.Resources = .{};
var font_24_inst: state_lib.TtfFont = undefined;
var font_20_inst: state_lib.TtfFont = undefined;
var font_16_inst: state_lib.TtfFont = undefined;
var anim_player_inst: state_lib.AnimPlayer = undefined;

var flush_tmp: [240 * 240]u16 = undefined;

pub fn init() void {
    Board.log.info("H106 Demo starting", .{});
    board.init() catch { Board.log.err("Board init failed", .{}); return; };

    sim_spi = websim.SimSpi.init(&sim_dc);
    disp = Display.init(&sim_spi, &sim_dc);

    Board.log.info("Loading assets (zero-copy)...", .{});

    var dummy: [8]u8 = undefined;
    res.bg = assets.loadImageFromFs(&board.fs, assets.PATH_BG, &dummy);
    res.ultraman = assets.loadImageFromFs(&board.fs, assets.PATH_ULTRAMAN, &dummy);
    for (0..5) |i| res.menu_icons[i] = assets.loadImageFromFs(&board.fs, assets.PATH_MENU_ITEMS[i], &dummy);
    res.btn_list = assets.loadImageFromFs(&board.fs, assets.PATH_BTN_LIST_ITEM, &dummy);
    for (0..4) |i| res.game_icons[i] = assets.loadImageFromFs(&board.fs, assets.PATH_GAME_ICONS[i], &dummy);
    for (0..9) |i| res.setting_icons[i] = assets.loadImageFromFs(&board.fs, assets.PATH_SETTING_ICONS[i], &dummy);
    res.icon_haivivi = assets.loadImageFromFs(&board.fs, assets.PATH_ICON_HAIVIVI, &dummy);
    res.intro_setting = assets.loadImageFromFs(&board.fs, assets.PATH_INTRO_SETTING, &dummy);
    res.intro_list = assets.loadImageFromFs(&board.fs, assets.PATH_INTRO_LIST, &dummy);
    res.intro_device = assets.loadImageFromFs(&board.fs, assets.PATH_INTRO_DEVICE, &dummy);
    res.intro_arrow = assets.loadImageFromFs(&board.fs, assets.PATH_INTRO_ARROW, &dummy);

    if (res.bg == null) { Board.log.err("Failed to load bg", .{}); return; }

    // Font (zero-copy)
    font_load: {
        var file = board.fs.open(assets.PATH_FONT, .read) orelse break :font_load;
        defer file.close();
        if (file.data) |data| {
            if (state_lib.TtfFont.init(data, 24.0)) |f| { font_24_inst = f; res.font_24 = &font_24_inst; }
            if (state_lib.TtfFont.init(data, 20.0)) |f| { font_20_inst = f; res.font_20 = &font_20_inst; }
            if (state_lib.TtfFont.init(data, 16.0)) |f| { font_16_inst = f; res.font_16 = &font_16_inst; }
        }
    }

    // Animation (zero-copy)
    anim_load: {
        var file = board.fs.open(assets.PATH_STARTUP_ANIM, .read) orelse break :anim_load;
        defer file.close();
        if (file.data) |data| {
            if (state_lib.AnimPlayer.init(data)) |p| { anim_player_inst = p; res.anim_player = &anim_player_inst; }
        }
    }

    Board.log.info("Assets loaded", .{});

    // Set initial state with animation frame count
    var initial_state = ui.AppState{};
    if (res.anim_player) |player| {
        initial_state.anim_total_frames = player.header.frame_count;
    }
    store = ui.Store.init(initial_state, ui.reduce);
    framebuf = ui.FB.init(0);
    ready = true;
    Board.log.info("H106 ready", .{});
}

var power_was_held: bool = false;

pub fn step() void {
    if (!ready) return;
    board.buttons.poll();

    const t = board.uptime();
    _ = board.button.poll(t);
    const power_held = board.button.driver.isPressed();
    if (power_held) store.dispatch(.power_hold)
    else if (power_was_held) store.dispatch(.power_release);
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
        ui.renderWithPrev(&framebuf, store.getState(), store.getPrev(), &res);
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
