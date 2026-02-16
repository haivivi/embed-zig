//! H106 UI Tests — state machine + render verification

const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

fn newStore() ui.Store { return ui.Store.init(.{}, ui.reduce); }
fn newStoreWith(initial: ui.AppState) ui.Store { return ui.Store.init(initial, ui.reduce); }

// ============================================================================
// Layer 1: Navigation State Machine
// ============================================================================

test "initial: startup" {
    const s = newStore().getState();
    try testing.expectEqual(ui.Page.startup, s.page);
    try testing.expectEqual(@as(?ui.Transition, null), s.transition);
}

test "startup: skip with confirm → desktop" {
    var store = newStore();
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
}

test "desktop → menu" {
    var s = ui.AppState{}; s.page = .desktop;
    var store = newStoreWith(s);
    store.dispatch(.right);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

test "transition completes" {
    var s = ui.AppState{}; s.page = .desktop;
    var store = newStoreWith(s);
    store.dispatch(.right);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.menu, store.getState().page);
    try testing.expectEqual(@as(?ui.Transition, null), store.getState().transition);
}

test "menu: left/right" {
    var s = ui.AppState{}; s.page = .menu; s.menu_index = 2;
    var store = newStoreWith(s);
    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 1), store.getState().menu_index);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 2), store.getState().menu_index);
}

test "menu: 0+left → desktop" {
    var s = ui.AppState{}; s.page = .menu; s.menu_index = 0;
    var store = newStoreWith(s);
    store.dispatch(.left);
    try testing.expectEqual(ui.Page.desktop, store.getState().transition.?.to);
}

test "menu: max stays" {
    var s = ui.AppState{}; s.page = .menu; s.menu_index = 4;
    var store = newStoreWith(s);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 4), store.getState().menu_index);
}

test "menu → game_list" {
    var s = ui.AppState{}; s.page = .menu; s.menu_index = 1;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

test "menu → settings" {
    var s = ui.AppState{}; s.page = .menu; s.menu_index = 4;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.settings, store.getState().transition.?.to);
}

test "game_list: up/down" {
    var s = ui.AppState{}; s.page = .game_list;
    var store = newStoreWith(s);
    store.dispatch(.down);
    try testing.expectEqual(@as(u8, 1), store.getState().game_index);
    store.dispatch(.down);
    try testing.expectEqual(@as(u8, 2), store.getState().game_index);
    store.dispatch(.up);
    try testing.expectEqual(@as(u8, 1), store.getState().game_index);
}

test "game_list: confirm tetris" {
    var s = ui.AppState{}; s.page = .game_list; s.game_index = 0;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.game_tetris, store.getState().transition.?.to);
}

test "game_list: confirm racer" {
    var s = ui.AppState{}; s.page = .game_list; s.game_index = 1;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.game_racer, store.getState().transition.?.to);
}

test "game_list: back → menu" {
    var s = ui.AppState{}; s.page = .game_list;
    var store = newStoreWith(s);
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

test "settings: up/down" {
    var s = ui.AppState{}; s.page = .settings;
    var store = newStoreWith(s);
    store.dispatch(.down);
    try testing.expectEqual(@as(u8, 1), store.getState().settings_index);
    store.dispatch(.down);
    try testing.expectEqual(@as(u8, 2), store.getState().settings_index);
}

test "settings: back → menu" {
    var s = ui.AppState{}; s.page = .settings;
    var store = newStoreWith(s);
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

test "game back → game_list" {
    var s = ui.AppState{}; s.page = .game_tetris;
    var store = newStoreWith(s);
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

test "tetris input" {
    var s = ui.AppState{}; s.page = .game_tetris;
    var store = newStoreWith(s);
    const y0 = store.getState().tetris.piece.y;
    store.dispatch(.down);
    try testing.expectEqual(y0 + 1, store.getState().tetris.piece.y);
}

test "power: long hold → shutdown → off" {
    var s = ui.AppState{}; s.page = .desktop;
    var store = newStoreWith(s);
    // Hold power for 180 ticks
    for (0..180) |_| store.dispatch(.power_hold);
    try testing.expectEqual(ui.Page.shutting_down, store.getState().page);
    // Wait for shutdown animation
    for (0..40) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.off, store.getState().page);
}

test "power: off → long hold → startup" {
    var s = ui.AppState{}; s.page = .off;
    var store = newStoreWith(s);
    for (0..180) |_| store.dispatch(.power_hold);
    try testing.expectEqual(ui.Page.startup, store.getState().page);
}

test "power: short hold does nothing" {
    var s = ui.AppState{}; s.page = .desktop;
    var store = newStoreWith(s);
    for (0..50) |_| store.dispatch(.power_hold);
    store.dispatch(.power_release);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
}

test "racer input" {
    var s = ui.AppState{}; s.page = .game_racer;
    var store = newStoreWith(s);
    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 0), store.getState().racer.player_lane);
}

// ============================================================================
// Layer 2: Render — pure function of (state, resources)
// ============================================================================

const empty_res = ui.Resources{};

test "render: desktop no crash" {
    var fb = ui.FB.init(ui.BLACK);
    var s = ui.AppState{}; s.page = .desktop;
    ui.render(&fb, &s, &empty_res);
}

test "render: menu dots" {
    var fb = ui.FB.init(ui.BLACK);
    var s = ui.AppState{}; s.page = .menu;
    ui.render(&fb, &s, &empty_res);
    var found = false;
    for (212..228) |y| for (80..160) |x| {
        const px = fb.getPixel(@intCast(x), @intCast(y));
        if (px == 0xFFFF or px == 0x7BEF) found = true;
    };
    try testing.expect(found);
}

test "render: game_list no crash" {
    var fb = ui.FB.init(ui.BLACK);
    var s = ui.AppState{}; s.page = .game_list;
    for (0..4) |i| { s.game_index = @intCast(i); ui.render(&fb, &s, &empty_res); }
}

test "render: settings no crash" {
    var fb = ui.FB.init(ui.BLACK);
    var s = ui.AppState{}; s.page = .settings;
    for (0..9) |i| { s.settings_index = @intCast(i); ui.render(&fb, &s, &empty_res); }
}

test "render: transition no crash" {
    var fb = ui.FB.init(ui.BLACK);
    var s = ui.AppState{}; s.page = .desktop; s.tick = 5;
    s.transition = .{ .from = .desktop, .to = .menu, .start_tick = 1, .duration = 12, .direction = .left };
    ui.render(&fb, &s, &empty_res);
    s.transition.?.direction = .right;
    ui.render(&fb, &s, &empty_res);
}

test "render: is pure function (same state → same output)" {
    var fb1 = ui.FB.init(ui.BLACK);
    var fb2 = ui.FB.init(ui.BLACK);
    var s = ui.AppState{}; s.page = .menu; s.menu_index = 2;
    ui.render(&fb1, &s, &empty_res);
    ui.render(&fb2, &s, &empty_res);
    // Same state + same resources → same pixels
    for (0..240) |y| for (0..240) |x| {
        try testing.expectEqual(fb1.getPixel(@intCast(x), @intCast(y)), fb2.getPixel(@intCast(x), @intCast(y)));
    };
}
