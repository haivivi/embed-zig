//! H106 UI Tests — comprehensive state machine + render verification
//!
//! Every test: setup state → dispatch event → assert state.
//! Organized by page. Covers all event paths per page.

const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

fn newStore() ui.Store { return ui.Store.init(.{}, ui.reduce); }
fn newStoreWith(s: ui.AppState) ui.Store { return ui.Store.init(s, ui.reduce); }
fn onPage(page: ui.Page) ui.AppState { var s = ui.AppState{}; s.page = page; return s; }

// ============================================================================
// Startup
// ============================================================================

test "startup: initial page" {
    const s = newStore().getState();
    try testing.expectEqual(ui.Page.startup, s.page);
    try testing.expectEqual(@as(u16, 0), s.anim_frame_index);
    try testing.expect(!s.anim_done);
}

test "startup: tick advances animation frame every 2 ticks" {
    var store = newStore();
    store.dispatch(.tick);
    try testing.expectEqual(@as(u16, 0), store.getState().anim_frame_index);
    store.dispatch(.tick);
    try testing.expectEqual(@as(u16, 1), store.getState().anim_frame_index);
}

test "startup: confirm + first_boot → intro" {
    var store = newStore(); // is_first_boot defaults to true
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.intro, store.getState().page);
}

test "startup: confirm + not first_boot → desktop" {
    var s = ui.AppState{}; s.is_first_boot = false;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
}

test "startup: back + first_boot → intro" {
    var store = newStore();
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.intro, store.getState().page);
}

test "startup: left/right/up/down ignored" {
    var store = newStore();
    store.dispatch(.left);
    store.dispatch(.right);
    store.dispatch(.up);
    store.dispatch(.down);
    try testing.expectEqual(ui.Page.startup, store.getState().page);
}

test "startup: anim_done + first_boot → intro" {
    var s = ui.AppState{}; s.anim_done = true; s.is_first_boot = true;
    var store = newStoreWith(s);
    store.dispatch(.tick);
    try testing.expectEqual(ui.Page.intro, store.getState().page);
}

test "startup: anim_done + not first_boot → desktop" {
    var s = ui.AppState{}; s.anim_done = true; s.is_first_boot = false;
    var store = newStoreWith(s);
    store.dispatch(.tick);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
}

// ============================================================================
// Intro (first boot guide, 3 pages)
// ============================================================================

test "intro: right advances" {
    var store = newStoreWith(onPage(.intro));
    try testing.expectEqual(@as(u8, 0), store.getState().intro_index);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 1), store.getState().intro_index);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 2), store.getState().intro_index);
    store.dispatch(.right); // max
    try testing.expectEqual(@as(u8, 2), store.getState().intro_index);
}

test "intro: left goes back" {
    var s = onPage(.intro); s.intro_index = 2;
    var store = newStoreWith(s);
    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 1), store.getState().intro_index);
    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 0), store.getState().intro_index);
    store.dispatch(.left); // min
    try testing.expectEqual(@as(u8, 0), store.getState().intro_index);
}

test "intro: confirm on last page → desktop, clears first_boot" {
    var s = onPage(.intro); s.intro_index = 2; s.is_first_boot = true;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.desktop, store.getState().transition.?.to);
    try testing.expect(!store.getState().is_first_boot);
}

test "intro: confirm on non-last advances" {
    var store = newStoreWith(onPage(.intro));
    store.dispatch(.confirm);
    try testing.expectEqual(@as(u8, 1), store.getState().intro_index);
}

test "intro: back skips to desktop, clears first_boot" {
    var s = onPage(.intro); s.is_first_boot = true;
    var store = newStoreWith(s);
    store.dispatch(.back);
    try testing.expect(!store.getState().is_first_boot);
    try testing.expectEqual(ui.Page.desktop, store.getState().transition.?.to);
}

// ============================================================================
// Desktop
// ============================================================================

test "desktop: right → menu" {
    var store = newStoreWith(onPage(.desktop));
    store.dispatch(.right);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
    try testing.expectEqual(ui.Transition.Dir.left, store.getState().transition.?.direction);
}

test "desktop: confirm → menu" {
    var store = newStoreWith(onPage(.desktop));
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

test "desktop: left/up/down/back ignored" {
    var store = newStoreWith(onPage(.desktop));
    store.dispatch(.left);
    store.dispatch(.up);
    store.dispatch(.down);
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
    try testing.expectEqual(@as(?ui.Transition, null), store.getState().transition);
}

// ============================================================================
// Menu (5 items: Team, Game, Contact, Points, Settings)
// ============================================================================

test "menu: right/left changes index" {
    var store = newStoreWith(onPage(.menu));
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 1), store.getState().menu_index);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 2), store.getState().menu_index);
    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 1), store.getState().menu_index);
}

test "menu: right at 4 stays" {
    var s = onPage(.menu); s.menu_index = 4;
    var store = newStoreWith(s);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 4), store.getState().menu_index);
}

test "menu: left at 0 → desktop" {
    var store = newStoreWith(onPage(.menu));
    store.dispatch(.left);
    try testing.expectEqual(ui.Page.desktop, store.getState().transition.?.to);
}

test "menu: back → desktop" {
    var store = newStoreWith(onPage(.menu));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.desktop, store.getState().transition.?.to);
}

test "menu: confirm 0 (Team) → no action (TODO)" {
    var store = newStoreWith(onPage(.menu));
    store.dispatch(.confirm);
    try testing.expectEqual(@as(?ui.Transition, null), store.getState().transition);
}

test "menu: confirm 1 → game_list" {
    var s = onPage(.menu); s.menu_index = 1;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

test "menu: confirm 2 → contact" {
    var s = onPage(.menu); s.menu_index = 2;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.contact, store.getState().transition.?.to);
}

test "menu: confirm 3 → points" {
    var s = onPage(.menu); s.menu_index = 3;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.points, store.getState().transition.?.to);
}

test "menu: confirm 4 → settings" {
    var s = onPage(.menu); s.menu_index = 4;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.settings, store.getState().transition.?.to);
}

// ============================================================================
// Game List (4 items)
// ============================================================================

test "game_list: down/up cycles" {
    var store = newStoreWith(onPage(.game_list));
    for (0..3) |_| store.dispatch(.down);
    try testing.expectEqual(@as(u8, 3), store.getState().game_index);
    store.dispatch(.down); // max
    try testing.expectEqual(@as(u8, 3), store.getState().game_index);
    store.dispatch(.up);
    try testing.expectEqual(@as(u8, 2), store.getState().game_index);
}

test "game_list: confirm 0 → tetris (resets)" {
    var s = onPage(.game_list); s.tetris.score = 999;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.game_tetris, store.getState().transition.?.to);
    try testing.expectEqual(@as(u32, 0), store.getState().tetris.score);
}

test "game_list: confirm 1 → racer (resets)" {
    var s = onPage(.game_list); s.game_index = 1; s.racer.score = 500;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.game_racer, store.getState().transition.?.to);
    try testing.expectEqual(@as(u32, 0), store.getState().racer.score);
}

test "game_list: back → menu" {
    var store = newStoreWith(onPage(.game_list));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

// ============================================================================
// Contact
// ============================================================================

test "contact: back → menu" {
    var store = newStoreWith(onPage(.contact));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

// ============================================================================
// Points
// ============================================================================

test "points: back → menu" {
    var store = newStoreWith(onPage(.points));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

// ============================================================================
// Settings (9 items, 3 sub-pages)
// ============================================================================

test "settings: down/up cycles 9 items" {
    var store = newStoreWith(onPage(.settings));
    for (0..8) |_| store.dispatch(.down);
    try testing.expectEqual(@as(u8, 8), store.getState().settings_index);
    store.dispatch(.down); // max
    try testing.expectEqual(@as(u8, 8), store.getState().settings_index);
}

test "settings: scroll adjusts" {
    var store = newStoreWith(onPage(.settings));
    for (0..8) |_| store.dispatch(.down);
    try testing.expect(store.getState().settings_scroll > 0);
}

test "settings: confirm 0 → lcd" {
    var store = newStoreWith(onPage(.settings));
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.settings_lcd, store.getState().transition.?.to);
}

test "settings: confirm 3 → reset" {
    var s = onPage(.settings); s.settings_index = 3;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.settings_reset, store.getState().transition.?.to);
}

test "settings: confirm 4 → info" {
    var s = onPage(.settings); s.settings_index = 4;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.settings_info, store.getState().transition.?.to);
}

test "settings: back → menu" {
    var store = newStoreWith(onPage(.settings));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

// ============================================================================
// Settings LCD (brightness: 10/55/85/100)
// ============================================================================

test "lcd: right increases brightness" {
    var s = onPage(.settings_lcd); s.lcd_brightness = 55;
    var store = newStoreWith(s);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 85), store.getState().lcd_brightness);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 100), store.getState().lcd_brightness);
    store.dispatch(.right); // max
    try testing.expectEqual(@as(u8, 100), store.getState().lcd_brightness);
}

test "lcd: left decreases brightness" {
    var s = onPage(.settings_lcd); s.lcd_brightness = 85;
    var store = newStoreWith(s);
    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 55), store.getState().lcd_brightness);
    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 10), store.getState().lcd_brightness);
    store.dispatch(.left); // min
    try testing.expectEqual(@as(u8, 10), store.getState().lcd_brightness);
}

test "lcd: back → settings" {
    var store = newStoreWith(onPage(.settings_lcd));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.settings, store.getState().transition.?.to);
}

// ============================================================================
// Settings Info
// ============================================================================

test "info: back → settings" {
    var store = newStoreWith(onPage(.settings_info));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.settings, store.getState().transition.?.to);
}

// ============================================================================
// Settings Reset
// ============================================================================

test "reset: confirm → full reset to startup" {
    var s = onPage(.settings_reset); s.is_first_boot = false;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.startup, store.getState().page);
    try testing.expect(store.getState().is_first_boot);
    try testing.expectEqual(@as(u16, 0), store.getState().anim_frame_index);
}

test "reset: back → settings" {
    var store = newStoreWith(onPage(.settings_reset));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.settings, store.getState().transition.?.to);
}

// ============================================================================
// Games
// ============================================================================

test "tetris: input forwarding" {
    var store = newStoreWith(onPage(.game_tetris));
    const y0 = store.getState().tetris.piece.y;
    store.dispatch(.down);
    try testing.expectEqual(y0 + 1, store.getState().tetris.piece.y);
}

test "tetris: back → game_list" {
    var store = newStoreWith(onPage(.game_tetris));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

test "racer: input forwarding" {
    var store = newStoreWith(onPage(.game_racer));
    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 0), store.getState().racer.player_lane);
}

test "racer: back → game_list" {
    var store = newStoreWith(onPage(.game_racer));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

// ============================================================================
// Power
// ============================================================================

test "power: long hold → shutdown → off" {
    var store = newStoreWith(onPage(.desktop));
    for (0..180) |_| store.dispatch(.power_hold);
    try testing.expectEqual(ui.Page.shutting_down, store.getState().page);
    for (0..40) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.off, store.getState().page);
}

test "power: off → long hold → startup" {
    var store = newStoreWith(onPage(.off));
    for (0..180) |_| store.dispatch(.power_hold);
    try testing.expectEqual(ui.Page.startup, store.getState().page);
}

test "power: short hold no effect" {
    var store = newStoreWith(onPage(.desktop));
    for (0..50) |_| store.dispatch(.power_hold);
    store.dispatch(.power_release);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
    try testing.expectEqual(@as(u16, 0), store.getState().power_hold_ticks);
}

test "power: works from any active page" {
    const pages = [_]ui.Page{ .desktop, .menu, .game_list, .settings, .contact, .points, .settings_lcd, .settings_info, .game_tetris, .game_racer };
    for (pages) |page| {
        var store = newStoreWith(onPage(page));
        for (0..180) |_| store.dispatch(.power_hold);
        try testing.expectEqual(ui.Page.shutting_down, store.getState().page);
    }
}

test "power: ignored during startup/intro" {
    var store = newStore(); // startup
    for (0..200) |_| store.dispatch(.power_hold);
    try testing.expectEqual(ui.Page.startup, store.getState().page);
}

// ============================================================================
// Transitions
// ============================================================================

test "transition: blocks events" {
    var store = newStoreWith(onPage(.desktop));
    store.dispatch(.right); // start transition
    store.dispatch(.left);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.desktop, store.getState().page); // not yet changed
}

test "transition: completes after duration" {
    var store = newStoreWith(onPage(.desktop));
    store.dispatch(.right);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.menu, store.getState().page);
    try testing.expectEqual(@as(?ui.Transition, null), store.getState().transition);
}

// ============================================================================
// Full navigation flow
// ============================================================================

test "full flow: startup → intro → desktop → menu → contact → back → menu → settings → lcd → back" {
    var store = newStore();
    // Skip startup → intro (first boot)
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.intro, store.getState().page);
    // Intro → desktop
    store.dispatch(.right); store.dispatch(.right); store.dispatch(.confirm);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
    // Desktop → menu
    store.dispatch(.right);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.menu, store.getState().page);
    // Menu → contact (index 2)
    store.dispatch(.right); store.dispatch(.right); store.dispatch(.confirm);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.contact, store.getState().page);
    // Contact → back to menu
    store.dispatch(.back);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.menu, store.getState().page);
    // Menu → settings (index 4)
    store.dispatch(.right); store.dispatch(.right); store.dispatch(.confirm);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.settings, store.getState().page);
    // Settings → lcd (index 0)
    store.dispatch(.confirm);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.settings_lcd, store.getState().page);
    // LCD → back to settings
    store.dispatch(.back);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.settings, store.getState().page);
}

// ============================================================================
// Render — pure function of (state, resources)
// ============================================================================

const empty_res = ui.Resources{};

test "render: every page no crash" {
    var fb = ui.FB.init(ui.BLACK);
    const pages = [_]ui.Page{
        .off, .startup, .intro, .desktop, .menu, .game_list, .settings,
        .settings_lcd, .settings_info, .settings_reset,
        .contact, .points, .game_tetris, .game_racer, .shutting_down,
    };
    for (pages) |page| {
        var s = ui.AppState{}; s.page = page;
        if (page == .shutting_down) s.shutdown_tick = 0;
        ui.render(&fb, &s, &empty_res);
    }
}

test "render: pure function" {
    var fb1 = ui.FB.init(ui.BLACK);
    var fb2 = ui.FB.init(ui.BLACK);
    var s = onPage(.menu); s.menu_index = 2;
    ui.render(&fb1, &s, &empty_res);
    ui.render(&fb2, &s, &empty_res);
    for (0..240) |y| for (0..240) |x| {
        try testing.expectEqual(fb1.getPixel(@intCast(x), @intCast(y)), fb2.getPixel(@intCast(x), @intCast(y)));
    };
}

test "render: different state → different pixels" {
    var fb1 = ui.FB.init(ui.BLACK);
    var fb2 = ui.FB.init(ui.BLACK);
    var s1 = onPage(.menu);
    s1.menu_index = 0;
    var s2 = onPage(.menu);
    s2.menu_index = 3;
    ui.render(&fb1, &s1, &empty_res);
    ui.render(&fb2, &s2, &empty_res);
    var differ = false;
    for (212..228) |y| for (80..160) |x| {
        if (fb1.getPixel(@intCast(x), @intCast(y)) != fb2.getPixel(@intCast(x), @intCast(y))) differ = true;
    };
    try testing.expect(differ);
}
