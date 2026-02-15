//! Tetris UI Tests
//!
//! Demonstrates how to test a ui_state application:
//!
//! Layer 1 — State Machine Tests:
//!   Create Store, dispatch events, assert state fields.
//!   Pure logic, no rendering involved.
//!
//! Layer 2 — Render Verification Tests:
//!   Given a known state, render to Framebuffer,
//!   assert specific pixels match expected colors.
//!
//! Run: bazel test //examples/apps/tetris:ui_test

const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

// ============================================================================
// Helpers
// ============================================================================

/// Create a fresh Store with default initial state.
fn newStore() ui.Store {
    return ui.Store.init(.{}, ui.reduce);
}

/// Create a Store with a specific initial state.
fn newStoreWith(initial: ui.GameState) ui.Store {
    return ui.Store.init(initial, ui.reduce);
}

/// Get pixel at a board cell position (top-left corner of the cell).
fn cellPixel(fb: *const ui.FB, col: usize, row: usize) u16 {
    const px: u16 = ui.BOARD_X + @as(u16, @intCast(col)) * ui.CELL_SIZE;
    const py: u16 = ui.BOARD_Y + @as(u16, @intCast(row)) * ui.CELL_SIZE;
    return fb.getPixel(px, py);
}

// ============================================================================
// Layer 1: State Machine Tests
//
// Pattern: dispatch event → assert state fields
// No Framebuffer, no rendering. Pure logic.
// ============================================================================

test "initial state: playing, empty board, piece at top" {
    const store = newStore();
    const s = store.getState();

    try testing.expectEqual(ui.GamePhase.playing, s.phase);
    try testing.expectEqual(@as(u32, 0), s.score);
    try testing.expectEqual(@as(u32, 0), s.lines);
    try testing.expectEqual(@as(u8, 1), s.level);
    try testing.expectEqual(@as(i8, 3), s.piece.x);
    try testing.expectEqual(@as(i8, 0), s.piece.y);

    // Board is empty
    for (0..ui.BOARD_H) |row| {
        for (0..ui.BOARD_W) |col| {
            try testing.expectEqual(@as(u8, 0), s.board[row][col]);
        }
    }
}

test "move_left: piece moves left by 1" {
    var store = newStore();
    const x_before = store.getState().piece.x;

    store.dispatch(.move_left);

    try testing.expectEqual(x_before - 1, store.getState().piece.x);
}

test "move_right: piece moves right by 1" {
    var store = newStore();
    const x_before = store.getState().piece.x;

    store.dispatch(.move_right);

    try testing.expectEqual(x_before + 1, store.getState().piece.x);
}

test "move_left: blocked at left wall" {
    // Start piece at x=0 so it can't go further left
    var state = ui.GameState{};
    state.piece.x = 0;
    var store = newStoreWith(state);

    store.dispatch(.move_left);

    // I-piece shape 0 (0x0F00) has cells at columns 0-3 of row 1.
    // At x=0, the leftmost cell is at board col 0.
    // move_left would put it at x=-1, col -1 → blocked.
    try testing.expectEqual(@as(i8, 0), store.getState().piece.x);
}

test "rotate: changes rotation" {
    var store = newStore();
    const rot_before = store.getState().piece.rot;

    store.dispatch(.rotate);

    try testing.expectEqual(rot_before +% 1, store.getState().piece.rot);
}

test "soft_drop: piece moves down by 1" {
    var store = newStore();
    const y_before = store.getState().piece.y;

    store.dispatch(.soft_drop);

    try testing.expectEqual(y_before + 1, store.getState().piece.y);
}

test "hard_drop: piece lands at bottom" {
    var store = newStore();
    store.commitFrame();

    store.dispatch(.hard_drop);

    const s = store.getState();
    // After hard drop, piece is locked and a new piece spawns at top
    try testing.expectEqual(@as(i8, 0), s.piece.y);
    // Board should have some non-zero cells (the locked piece)
    var has_piece = false;
    for (0..ui.BOARD_H) |row| {
        for (0..ui.BOARD_W) |col| {
            if (s.board[row][col] != 0) has_piece = true;
        }
    }
    try testing.expect(has_piece);
}

test "hard_drop: I-piece lands on bottom row" {
    // I-piece shape 0 (0x0F00): cells at (0,1),(1,1),(2,1),(3,1)
    // Starting at x=3,y=0, hard drop should land at bottom.
    var store = newStore();
    store.dispatch(.hard_drop);

    const s = store.getState();
    // I-piece occupies row 1 of its 4x4 grid → board row = piece.y + 1
    // After lock, bottom row (19) should have the I-piece.
    // Check row 19 has 4 consecutive filled cells at columns 3-6
    const bottom = ui.BOARD_H - 1;
    try testing.expect(s.board[bottom][3] != 0);
    try testing.expect(s.board[bottom][4] != 0);
    try testing.expect(s.board[bottom][5] != 0);
    try testing.expect(s.board[bottom][6] != 0);
    // Adjacent cells should be empty
    try testing.expectEqual(@as(u8, 0), s.board[bottom][2]);
    try testing.expectEqual(@as(u8, 0), s.board[bottom][7]);
}

test "line clear: full row awards 100 points" {
    // Set up a board where row 19 is almost full (9/10 cells filled),
    // then drop a piece to complete it.
    var state = ui.GameState{};
    // Fill row 19 except column 5 (leave a gap for I-piece)
    for (0..ui.BOARD_W) |col| {
        if (col < 3 or col > 6) {
            state.board[ui.BOARD_H - 1][col] = 1; // some piece color
        }
    }
    // Place I-piece (shape 0) at x=3, it fills cols 3-6 at row+1
    state.piece = .{ .shape = 0, .rot = 0, .x = 3, .y = 0 };

    var store = newStoreWith(state);
    store.dispatch(.hard_drop);

    const s = store.getState();
    try testing.expectEqual(@as(u32, 100), s.score);
    try testing.expectEqual(@as(u32, 1), s.lines);

    // Cleared row should now be empty (everything shifted down)
    for (0..ui.BOARD_W) |col| {
        try testing.expectEqual(@as(u8, 0), s.board[ui.BOARD_H - 1][col]);
    }
}

test "game over: piece spawns into occupied space" {
    // Checkerboard pattern: no row is completely full (no line clearing),
    // but spawn area is blocked so next piece collides → game over.
    var state = ui.GameState{};
    for (0..ui.BOARD_H) |row| {
        for (0..ui.BOARD_W) |col| {
            state.board[row][col] = if ((row + col) % 2 == 0) @as(u8, 1) else 0;
        }
    }
    var store = newStoreWith(state);
    store.dispatch(.hard_drop);

    try testing.expectEqual(ui.GamePhase.game_over, store.getState().phase);
}

test "game over: events are ignored" {
    var state = ui.GameState{};
    state.phase = .game_over;
    state.score = 42;
    var store = newStoreWith(state);

    store.dispatch(.move_left);
    store.dispatch(.move_right);
    store.dispatch(.rotate);
    store.dispatch(.soft_drop);

    // State unchanged
    try testing.expectEqual(@as(u32, 42), store.getState().score);
    try testing.expectEqual(ui.GamePhase.game_over, store.getState().phase);
}

test "restart: resets everything" {
    var state = ui.GameState{};
    state.score = 9999;
    state.lines = 50;
    state.level = 6;
    state.phase = .game_over;
    var store = newStoreWith(state);

    store.dispatch(.restart);

    const s = store.getState();
    try testing.expectEqual(ui.GamePhase.playing, s.phase);
    try testing.expectEqual(@as(u32, 0), s.score);
    try testing.expectEqual(@as(u32, 0), s.lines);
    try testing.expectEqual(@as(u8, 1), s.level);
}

test "level up: every 10 lines increases level" {
    var state = ui.GameState{};
    state.lines = 9;
    state.level = 1;
    // Fill row 19 except cols 3-6 for I-piece
    for (0..ui.BOARD_W) |col| {
        if (col < 3 or col > 6) {
            state.board[ui.BOARD_H - 1][col] = 1;
        }
    }
    state.piece = .{ .shape = 0, .rot = 0, .x = 3, .y = 0 };

    var store = newStoreWith(state);
    store.dispatch(.hard_drop);

    const s = store.getState();
    try testing.expectEqual(@as(u32, 10), s.lines);
    try testing.expectEqual(@as(u8, 2), s.level);
}

// ============================================================================
// Layer 2: Render Verification Tests
//
// Pattern: construct state → render to Framebuffer → assert pixels
// Verifies that state produces expected visual output.
// ============================================================================

test "render: empty board shows DARK_GRAY background" {
    var fb = ui.FB.init(ui.BLACK);
    ui.drawStatic(&fb);

    const state = ui.GameState{};
    const prev = ui.GameState{};
    // First render with empty state (piece is at top, diff vs prev)
    ui.render(&fb, &state, &prev);

    // A cell in the middle of the empty board should be DARK_GRAY
    // (row 10, col 5 — no piece, no locked block)
    try testing.expectEqual(ui.DARK_GRAY, cellPixel(&fb, 5, 10));
}

test "render: locked piece shows piece color" {
    var fb = ui.FB.init(ui.BLACK);
    ui.drawStatic(&fb);

    // Create a state with a locked I-piece (shape 0, color index 1) at row 19
    var state = ui.GameState{};
    state.board[19][3] = 1; // I-piece = shape 0, stored as shape+1=1
    state.board[19][4] = 1;
    state.board[19][5] = 1;
    state.board[19][6] = 1;

    var prev = ui.GameState{}; // empty prev → everything redraws

    // Force piece to a position that doesn't overlap (off the checked area)
    state.piece.y = 0;
    prev.piece.y = 0;

    ui.render(&fb, &state, &prev);

    // Cells (3,19) through (6,19) should be I-piece cyan (PIECE_COLORS[0])
    try testing.expectEqual(ui.PIECE_COLORS[0], cellPixel(&fb, 3, 19));
    try testing.expectEqual(ui.PIECE_COLORS[0], cellPixel(&fb, 4, 19));
    try testing.expectEqual(ui.PIECE_COLORS[0], cellPixel(&fb, 5, 19));
    try testing.expectEqual(ui.PIECE_COLORS[0], cellPixel(&fb, 6, 19));

    // Adjacent empty cell should be DARK_GRAY
    try testing.expectEqual(ui.DARK_GRAY, cellPixel(&fb, 2, 19));
    try testing.expectEqual(ui.DARK_GRAY, cellPixel(&fb, 7, 19));
}

test "render: active piece shows at correct position" {
    var fb = ui.FB.init(ui.BLACK);
    ui.drawStatic(&fb);

    // State with I-piece at x=3, y=5 (row 1 of I-piece → board row 6)
    var state = ui.GameState{};
    state.piece = .{ .shape = 0, .rot = 0, .x = 3, .y = 5 };

    var prev = ui.GameState{};
    prev.piece = .{ .shape = 0, .rot = 0, .x = 3, .y = 99 }; // force diff

    ui.render(&fb, &state, &prev);

    // I-piece shape 0 (0x0F00): cells at row 1, cols 0-3 of 4x4 grid
    // Board position: row = 5+1 = 6, cols = 3,4,5,6
    const i_cyan = ui.PIECE_COLORS[0];
    try testing.expectEqual(i_cyan, cellPixel(&fb, 3, 6));
    try testing.expectEqual(i_cyan, cellPixel(&fb, 4, 6));
    try testing.expectEqual(i_cyan, cellPixel(&fb, 5, 6));
    try testing.expectEqual(i_cyan, cellPixel(&fb, 6, 6));

    // Row above (5) should not have the piece (I-shape row 0 is empty)
    try testing.expectEqual(ui.DARK_GRAY, cellPixel(&fb, 3, 5));
}

test "render: score display shows digit pixels" {
    var fb = ui.FB.init(ui.BLACK);

    var state = ui.GameState{};
    state.score = 100;
    var prev = ui.GameState{}; // score 0 → triggers redraw

    ui.render(&fb, &state, &prev);

    // Score "100" rendered at (INFO_X, 30).
    // Digit '1' bitmap row 0 = 0x20 → bit pattern: ..#.....
    // So pixel at (INFO_X + 2, 30) should be WHITE (the '1' top pixel)
    try testing.expectEqual(ui.WHITE, fb.getPixel(ui.INFO_X + 2, 30));

    // And pixel at (INFO_X + 0, 30) should be BLACK (no bit set for '1' at col 0)
    try testing.expectEqual(ui.BLACK, fb.getPixel(ui.INFO_X + 0, 30));
}

test "render: diff rendering skips unchanged cells" {
    var fb = ui.FB.init(ui.BLACK);
    ui.drawStatic(&fb);

    var state = ui.GameState{};
    state.piece = .{ .shape = 0, .rot = 0, .x = 3, .y = 5 };

    // First render
    var prev = state; // same as state → no diff
    ui.render(&fb, &state, &prev);
    fb.clearDirty();

    // No change → render should produce no dirty rects
    ui.render(&fb, &state, &prev);
    try testing.expectEqual(@as(usize, 0), fb.getDirtyRects().len);

    // Now move piece → should produce dirty rects
    var new_state = state;
    new_state.piece.y = 6;
    ui.render(&fb, &new_state, &state);
    try testing.expect(fb.getDirtyRects().len > 0);
}

test "render: game over does not render active piece" {
    var fb = ui.FB.init(ui.BLACK);
    ui.drawStatic(&fb);

    var state = ui.GameState{};
    state.phase = .game_over;
    state.piece = .{ .shape = 0, .rot = 0, .x = 3, .y = 5 };

    var prev = ui.GameState{};
    prev.phase = .game_over;
    prev.piece.y = 99;

    ui.render(&fb, &state, &prev);

    // isPieceAt returns null when game_over → piece should NOT render
    // Cell (3,6) where I-piece would be should remain DARK_GRAY
    try testing.expectEqual(ui.DARK_GRAY, cellPixel(&fb, 3, 6));
}
