//! H106 UI Tests
//!
//! Layer 1: Page navigation state machine
//! Layer 2: Render pixel verification

const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

fn newStore() ui.Store {
    return ui.Store.init(.{}, ui.reduce);
}

fn newStoreWith(initial: ui.AppState) ui.Store {
    return ui.Store.init(initial, ui.reduce);
}

// ============================================================================
// Layer 1: Navigation State Machine
// ============================================================================

test "initial state: desktop" {
    const s = newStore().getState();
    try testing.expectEqual(ui.Page.desktop, s.page);
    try testing.expectEqual(@as(u8, 0), s.menu_index);
    try testing.expectEqual(@as(?ui.Transition, null), s.transition);
}

test "desktop → menu: right key starts transition" {
    var store = newStore();
    store.dispatch(.right);
    const s = store.getState();
    try testing.expect(s.transition != null);
    try testing.expectEqual(ui.Page.desktop, s.transition.?.from);
    try testing.expectEqual(ui.Page.menu, s.transition.?.to);
}

test "transition completes after duration ticks" {
    var store = newStore();
    store.dispatch(.right); // desktop → menu transition
    // Tick through the transition duration
    for (0..12) |_| store.dispatch(.tick);
    const s = store.getState();
    try testing.expectEqual(ui.Page.menu, s.page);
    try testing.expectEqual(@as(?ui.Transition, null), s.transition);
}

test "menu: left/right changes menu_index" {
    var state = ui.AppState{};
    state.page = .menu;
    state.menu_index = 2;
    var store = newStoreWith(state);

    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 1), store.getState().menu_index);

    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 2), store.getState().menu_index);
}

test "menu: index 0 + left → back to desktop" {
    var state = ui.AppState{};
    state.page = .menu;
    state.menu_index = 0;
    var store = newStoreWith(state);

    store.dispatch(.left);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.desktop, store.getState().transition.?.to);
}

test "menu: right at max stays at max" {
    var state = ui.AppState{};
    state.page = .menu;
    state.menu_index = 4;
    var store = newStoreWith(state);

    store.dispatch(.right);
    try testing.expectEqual(@as(u8, 4), store.getState().menu_index);
}

test "menu: confirm on Game → game_list" {
    var state = ui.AppState{};
    state.page = .menu;
    state.menu_index = 1; // Game
    var store = newStoreWith(state);

    store.dispatch(.confirm);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

test "menu: confirm on Settings → settings" {
    var state = ui.AppState{};
    state.page = .menu;
    state.menu_index = 4; // Settings
    var store = newStoreWith(state);

    store.dispatch(.confirm);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.settings, store.getState().transition.?.to);
}

test "game_list: up/down changes game_index" {
    var state = ui.AppState{};
    state.page = .game_list;
    state.game_index = 0;
    var store = newStoreWith(state);

    store.dispatch(.down);
    try testing.expectEqual(@as(u8, 1), store.getState().game_index);

    store.dispatch(.up);
    try testing.expectEqual(@as(u8, 0), store.getState().game_index);
}

test "game_list: confirm launches tetris" {
    var state = ui.AppState{};
    state.page = .game_list;
    state.game_index = 0; // Tetris
    var store = newStoreWith(state);

    store.dispatch(.confirm);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.game_tetris, store.getState().transition.?.to);
}

test "game_list: confirm launches racer" {
    var state = ui.AppState{};
    state.page = .game_list;
    state.game_index = 1; // Racer
    var store = newStoreWith(state);

    store.dispatch(.confirm);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.game_racer, store.getState().transition.?.to);
}

test "game_list: back → menu" {
    var state = ui.AppState{};
    state.page = .game_list;
    var store = newStoreWith(state);

    store.dispatch(.back);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

test "game_tetris: back → game_list" {
    var state = ui.AppState{};
    state.page = .game_tetris;
    var store = newStoreWith(state);

    store.dispatch(.back);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

test "game_racer: back → game_list" {
    var state = ui.AppState{};
    state.page = .game_racer;
    var store = newStoreWith(state);

    store.dispatch(.back);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.game_list, store.getState().transition.?.to);
}

test "settings: back → menu" {
    var state = ui.AppState{};
    state.page = .settings;
    var store = newStoreWith(state);

    store.dispatch(.back);
    try testing.expect(store.getState().transition != null);
    try testing.expectEqual(ui.Page.menu, store.getState().transition.?.to);
}

test "tetris input forwarded in game page" {
    var state = ui.AppState{};
    state.page = .game_tetris;
    var store = newStoreWith(state);

    const y_before = store.getState().tetris.piece.y;
    store.dispatch(.down); // soft_drop
    try testing.expectEqual(y_before + 1, store.getState().tetris.piece.y);
}

test "racer input forwarded in game page" {
    var state = ui.AppState{};
    state.page = .game_racer;
    var store = newStoreWith(state);

    store.dispatch(.left);
    try testing.expectEqual(@as(u8, 0), store.getState().racer.player_lane);
}

// ============================================================================
// Layer 2: Render Verification
// ============================================================================

test "render: desktop draws ultraman image" {
    var fb = ui.FB.init(ui.BLACK);
    var state = ui.AppState{};
    state.page = .desktop;
    ui.render(&fb, &state);

    // Center pixel should not be black (ultraman image has content)
    try testing.expect(fb.getPixel(120, 120) != ui.BLACK);
}

test "render: menu draws background and dots" {
    var fb = ui.FB.init(ui.BLACK);
    var state = ui.AppState{};
    state.page = .menu;
    state.menu_index = 0;
    ui.render(&fb, &state);

    // Dot indicator area should have some white pixels
    var has_white = false;
    for (210..230) |y| {
        for (80..160) |x| {
            if (fb.getPixel(@intCast(x), @intCast(y)) == ui.WHITE or
                fb.getPixel(@intCast(x), @intCast(y)) == ui.DIM_WHITE) has_white = true;
        }
    }
    try testing.expect(has_white);
}

test "render: game list shows selection highlight" {
    var fb = ui.FB.init(ui.BLACK);
    var state = ui.AppState{};
    state.page = .game_list;
    state.game_index = 0;
    ui.render(&fb, &state);

    // Selected item area should have accent color border
    var has_accent = false;
    for (60..100) |y| {
        for (20..220) |x| {
            if (fb.getPixel(@intCast(x), @intCast(y)) == ui.ACCENT) has_accent = true;
        }
    }
    try testing.expect(has_accent);
}
