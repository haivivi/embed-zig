//! H106 UI Tests — comprehensive state machine + render verification
//!
//! Every test follows the pattern: setup state → dispatch event → assert state.
//! Tests are organized by page, covering all event paths.

const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

fn newStore() ui.Store { return ui.Store.init(.{}, ui.reduce); }
fn newStoreWith(initial: ui.AppState) ui.Store { return ui.Store.init(initial, ui.reduce); }
fn onPage(page: ui.Page) ui.AppState { var s = ui.AppState{}; s.page = page; return s; }

// ============================================================================
// Startup
// ============================================================================

test "startup: initial page" {
    try testing.expectEqual(ui.Page.startup, newStore().getState().page);
    try testing.expectEqual(@as(u16, 0), newStore().getState().anim_frame_index);
    try testing.expectEqual(false, newStore().getState().anim_done);
}

test "startup: tick advances animation frame" {
    var store = newStore();
    // 2 ticks per animation frame (60fps render / 30fps anim)
    store.dispatch(.tick);
    try testing.expectEqual(@as(u16, 0), store.getState().anim_frame_index); // timer=1, not yet
    store.dispatch(.tick);
    try testing.expectEqual(@as(u16, 1), store.getState().anim_frame_index); // timer=2 → advance
    store.dispatch(.tick);
    store.dispatch(.tick);
    try testing.expectEqual(@as(u16, 2), store.getState().anim_frame_index);
}

test "startup: confirm skips to desktop" {
    var store = newStore();
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
    try testing.expect(store.getState().anim_done);
}

test "startup: back skips to desktop" {
    var store = newStore();
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
}

test "startup: left/right/up/down ignored" {
    var store = newStore();
    store.dispatch(.left);
    store.dispatch(.right);
    store.dispatch(.up);
    store.dispatch(.down);
    try testing.expectEqual(ui.Page.startup, store.getState().page);
}

test "startup: anim_done transitions to desktop" {
    var s = ui.AppState{}; s.page = .startup; s.anim_done = true;
    var store = newStoreWith(s);
    store.dispatch(.tick);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
}

// ============================================================================
// Desktop
// ============================================================================

test "desktop: right → menu transition" {
    var store = newStoreWith(onPage(.desktop));
    store.dispatch(.right);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
    try testing.expectEqual(ui.Transition.Dir.left, store.getState().transition.?.direction);
}

test "desktop: confirm → menu transition" {
    var store = newStoreWith(onPage(.desktop));
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

test "desktop: left/up/down/back ignored" {
    var store = newStoreWith(onPage(.desktop));
    store.dispatch(.left);
    try testing.expectEqual(@as(?ui.Transition, null), store.getState().transition);
    store.dispatch(.up);
    store.dispatch(.down);
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
}

// ============================================================================
// Menu
// ============================================================================

test "menu: initial index is 0" {
    try testing.expectEqual(@as(u8, 0), onPage(.menu).menu_index);
}

test "menu: right increments index" {
    var s = onPage(.menu); s.menu_index = 0;
    var store = newStoreWith(s);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 1), store.getState().menu_index);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 2), store.getState().menu_index);
}

test "menu: left decrements index" {
    var s = onPage(.menu); s.menu_index = 3;
    var store = newStoreWith(s);
    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 2), store.getState().menu_index);
}

test "menu: right at max (4) stays" {
    var s = onPage(.menu); s.menu_index = 4;
    var store = newStoreWith(s);
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 4), store.getState().menu_index);
}

test "menu: left at 0 → desktop" {
    var s = onPage(.menu); s.menu_index = 0;
    var store = newStoreWith(s);
    store.dispatch(.left);
    try testing.expectEqual(ui.Page.desktop, store.getState().transition.?.to);
    try testing.expectEqual(ui.Transition.Dir.right, store.getState().transition.?.direction);
}

test "menu: back → desktop" {
    var store = newStoreWith(onPage(.menu));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.desktop, store.getState().transition.?.to);
}

test "menu: confirm index=0 (Team) → no transition" {
    var s = onPage(.menu); s.menu_index = 0;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(@as(?ui.Transition, null), store.getState().transition);
}

test "menu: confirm index=1 (Game) → game_list" {
    var s = onPage(.menu); s.menu_index = 1;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

test "menu: confirm index=2 (Contact) → no transition" {
    var s = onPage(.menu); s.menu_index = 2;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(@as(?ui.Transition, null), store.getState().transition);
}

test "menu: confirm index=3 (Points) → no transition" {
    var s = onPage(.menu); s.menu_index = 3;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(@as(?ui.Transition, null), store.getState().transition);
}

test "menu: confirm index=4 (Settings) → settings" {
    var s = onPage(.menu); s.menu_index = 4;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.settings, store.getState().transition.?.to);
}

// ============================================================================
// Game List
// ============================================================================

test "game_list: down cycles through 4 items" {
    var store = newStoreWith(onPage(.game_list));
    try testing.expectEqual(@as(u8, 0), store.getState().game_index);
    store.dispatch(.down);
    try testing.expectEqual(@as(u8, 1), store.getState().game_index);
    store.dispatch(.down);
    try testing.expectEqual(@as(u8, 2), store.getState().game_index);
    store.dispatch(.down);
    try testing.expectEqual(@as(u8, 3), store.getState().game_index);
    store.dispatch(.down); // at max
    try testing.expectEqual(@as(u8, 3), store.getState().game_index);
}

test "game_list: up at 0 stays" {
    var store = newStoreWith(onPage(.game_list));
    store.dispatch(.up);
    try testing.expectEqual(@as(u8, 0), store.getState().game_index);
}

test "game_list: confirm 0 → tetris (resets game state)" {
    var s = onPage(.game_list); s.game_index = 0;
    s.tetris.score = 9999; // dirty state from previous game
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.game_tetris, store.getState().transition.?.to);
    try testing.expectEqual(@as(u32, 0), store.getState().tetris.score); // reset
}

test "game_list: confirm 1 → racer (resets game state)" {
    var s = onPage(.game_list); s.game_index = 1;
    s.racer.score = 500;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.game_racer, store.getState().transition.?.to);
    try testing.expectEqual(@as(u32, 0), store.getState().racer.score);
}

test "game_list: confirm 2/3 → no transition (not implemented)" {
    var s = onPage(.game_list); s.game_index = 2;
    var store = newStoreWith(s);
    store.dispatch(.confirm);
    try testing.expectEqual(@as(?ui.Transition, null), store.getState().transition);
}

test "game_list: back → menu" {
    var store = newStoreWith(onPage(.game_list));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
    try testing.expectEqual(ui.Transition.Dir.right, store.getState().transition.?.direction);
}

// ============================================================================
// Settings
// ============================================================================

test "settings: down cycles through 9 items" {
    var store = newStoreWith(onPage(.settings));
    for (0..8) |_| store.dispatch(.down);
    try testing.expectEqual(@as(u8, 8), store.getState().settings_index);
    store.dispatch(.down); // at max
    try testing.expectEqual(@as(u8, 8), store.getState().settings_index);
}

test "settings: up at 0 stays" {
    var store = newStoreWith(onPage(.settings));
    store.dispatch(.up);
    try testing.expectEqual(@as(u8, 0), store.getState().settings_index);
}

test "settings: scroll adjusts when navigating down" {
    var store = newStoreWith(onPage(.settings));
    // Scroll starts at 0
    try testing.expectEqual(@as(u16, 0), store.getState().settings_scroll);
    // Navigate to bottom items → scroll should increase
    for (0..8) |_| store.dispatch(.down);
    try testing.expect(store.getState().settings_scroll > 0);
}

test "settings: back → menu" {
    var store = newStoreWith(onPage(.settings));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

// ============================================================================
// Games — input forwarding
// ============================================================================

test "tetris: left moves piece" {
    var store = newStoreWith(onPage(.game_tetris));
    const x0 = store.getState().tetris.piece.x;
    store.dispatch(.left);
    try testing.expectEqual(x0 - 1, store.getState().tetris.piece.x);
}

test "tetris: right moves piece" {
    var store = newStoreWith(onPage(.game_tetris));
    const x0 = store.getState().tetris.piece.x;
    store.dispatch(.right);
    try testing.expectEqual(x0 + 1, store.getState().tetris.piece.x);
}

test "tetris: down soft drops" {
    var store = newStoreWith(onPage(.game_tetris));
    const y0 = store.getState().tetris.piece.y;
    store.dispatch(.down);
    try testing.expectEqual(y0 + 1, store.getState().tetris.piece.y);
}

test "tetris: confirm rotates" {
    var store = newStoreWith(onPage(.game_tetris));
    const r0 = store.getState().tetris.piece.rot;
    store.dispatch(.confirm);
    try testing.expectEqual(r0 +% 1, store.getState().tetris.piece.rot);
}

test "tetris: up hard drops" {
    var store = newStoreWith(onPage(.game_tetris));
    store.dispatch(.up);
    // After hard drop, piece locks and new piece spawns at y=0
    try testing.expectEqual(@as(i8, 0), store.getState().tetris.piece.y);
}

test "tetris: back → game_list" {
    var store = newStoreWith(onPage(.game_tetris));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

test "racer: left switches lane" {
    var store = newStoreWith(onPage(.game_racer));
    try testing.expectEqual(@as(u8, 1), store.getState().racer.player_lane); // starts center
    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 0), store.getState().racer.player_lane);
}

test "racer: right switches lane" {
    var store = newStoreWith(onPage(.game_racer));
    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 2), store.getState().racer.player_lane);
}

test "racer: back → game_list" {
    var store = newStoreWith(onPage(.game_racer));
    store.dispatch(.back);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

// ============================================================================
// Power on/off
// ============================================================================

test "power: long hold from desktop → shutting_down" {
    var store = newStoreWith(onPage(.desktop));
    for (0..180) |_| store.dispatch(.power_hold);
    try testing.expectEqual(ui.Page.shutting_down, store.getState().page);
}

test "power: shutting_down → off after duration" {
    const s = onPage(.desktop);
    var store = newStoreWith(s);
    for (0..180) |_| store.dispatch(.power_hold);
    for (0..40) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.off, store.getState().page);
}

test "power: off → long hold → startup" {
    var store = newStoreWith(onPage(.off));
    for (0..180) |_| store.dispatch(.power_hold);
    try testing.expectEqual(ui.Page.startup, store.getState().page);
    try testing.expectEqual(@as(u16, 0), store.getState().anim_frame_index);
    try testing.expectEqual(false, store.getState().anim_done);
}

test "power: short hold (50 ticks) → no effect" {
    var store = newStoreWith(onPage(.desktop));
    for (0..50) |_| store.dispatch(.power_hold);
    store.dispatch(.power_release);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
    try testing.expectEqual(@as(u16, 0), store.getState().power_hold_ticks); // reset on release
}

test "power: hold from menu → shutting_down" {
    var store = newStoreWith(onPage(.menu));
    for (0..180) |_| store.dispatch(.power_hold);
    try testing.expectEqual(ui.Page.shutting_down, store.getState().page);
}

test "power: hold from game → shutting_down" {
    var store = newStoreWith(onPage(.game_tetris));
    for (0..180) |_| store.dispatch(.power_hold);
    try testing.expectEqual(ui.Page.shutting_down, store.getState().page);
}

test "power: hold during startup ignored" {
    var store = newStore(); // starts at .startup
    for (0..200) |_| store.dispatch(.power_hold);
    try testing.expectEqual(ui.Page.startup, store.getState().page); // not shutting_down
}

test "power: release resets counter" {
    var store = newStoreWith(onPage(.desktop));
    for (0..100) |_| store.dispatch(.power_hold);
    try testing.expect(store.getState().power_hold_ticks > 0);
    store.dispatch(.power_release);
    try testing.expectEqual(@as(u16, 0), store.getState().power_hold_ticks);
}

// ============================================================================
// Transitions
// ============================================================================

test "transition: events blocked during transition" {
    const s = onPage(.desktop);
    var store = newStoreWith(s);
    store.dispatch(.right); // starts transition to menu
    try testing.expect(store.getState().transition != null);
    // During transition, further nav events are ignored
    store.dispatch(.left);
    store.dispatch(.confirm);
    store.dispatch(.back);
    // Still in transition, page hasn't changed yet
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
}

test "transition: completes after duration ticks" {
    var store = newStoreWith(onPage(.desktop));
    store.dispatch(.right);
    const duration = store.getState().transition.?.duration;
    for (0..duration + 2) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.menu, store.getState().page);
    try testing.expectEqual(@as(?ui.Transition, null), store.getState().transition);
}

test "transition: game tick forwarded during transition" {
    var s = onPage(.game_tetris);
    s.tetris.tick_count = 0;
    var store = newStoreWith(s);
    store.dispatch(.back); // transition to game_list
    store.dispatch(.tick); // should still tick the game
    try testing.expect(store.getState().tetris.tick_count > 0);
}

// ============================================================================
// Full navigation flow
// ============================================================================

test "full flow: startup → desktop → menu → game_list → tetris → back → back → back → desktop" {
    var store = newStore();

    // Skip startup
    store.dispatch(.confirm);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);

    // Desktop → Menu
    store.dispatch(.right);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.menu, store.getState().page);

    // Menu → select Game (index 1)
    store.dispatch(.right); // index 0→1
    store.dispatch(.confirm);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.game_list, store.getState().page);

    // Game list → Tetris
    store.dispatch(.confirm);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.game_tetris, store.getState().page);

    // Play a bit
    store.dispatch(.left);
    store.dispatch(.down);

    // Tetris → back to game_list
    store.dispatch(.back);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.game_list, store.getState().page);

    // Game list → back to menu
    store.dispatch(.back);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.menu, store.getState().page);

    // Menu → back to desktop
    store.dispatch(.back);
    for (0..14) |_| store.dispatch(.tick);
    try testing.expectEqual(ui.Page.desktop, store.getState().page);
}

// ============================================================================
// Layer 2: Render — pure function of (state, resources)
// ============================================================================

const empty_res = ui.Resources{};

test "render: every page without crash" {
    var fb = ui.FB.init(ui.BLACK);
    const pages = [_]ui.Page{ .off, .startup, .desktop, .menu, .game_list, .settings, .game_tetris, .game_racer, .shutting_down };
    for (pages) |page| {
        var s = ui.AppState{};
        s.page = page;
        if (page == .shutting_down) s.shutdown_tick = 0;
        ui.render(&fb, &s, &empty_res);
    }
}

test "render: menu dots present" {
    var fb = ui.FB.init(ui.BLACK);
    const s = onPage(.menu);
    ui.render(&fb, &s, &empty_res);
    var found = false;
    for (212..228) |y| for (80..160) |x| {
        const px = fb.getPixel(@intCast(x), @intCast(y));
        if (px == 0xFFFF or px == 0x7BEF) found = true;
    };
    try testing.expect(found);
}

test "render: pure function (same input → same output)" {
    var fb1 = ui.FB.init(ui.BLACK);
    var fb2 = ui.FB.init(ui.BLACK);
    var s = onPage(.menu); s.menu_index = 2;
    ui.render(&fb1, &s, &empty_res);
    ui.render(&fb2, &s, &empty_res);
    for (0..240) |y| for (0..240) |x| {
        try testing.expectEqual(fb1.getPixel(@intCast(x), @intCast(y)), fb2.getPixel(@intCast(x), @intCast(y)));
    };
}

test "render: different state → different output" {
    var fb1 = ui.FB.init(ui.BLACK);
    var fb2 = ui.FB.init(ui.BLACK);
    var s1 = onPage(.menu);
    s1.menu_index = 0;
    var s2 = onPage(.menu);
    s2.menu_index = 3;
    ui.render(&fb1, &s1, &empty_res);
    ui.render(&fb2, &s2, &empty_res);
    // Dots should be in different positions
    var differ = false;
    for (212..228) |y| for (80..160) |x| {
        if (fb1.getPixel(@intCast(x), @intCast(y)) != fb2.getPixel(@intCast(x), @intCast(y))) differ = true;
    };
    try testing.expect(differ);
}
