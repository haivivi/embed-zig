//! Tetris UI — State Machine + Render Logic
//!
//! Pure logic layer, no platform dependencies.
//! Only depends on ui_state framework.
//!
//! This file defines:
//! - GameState: the complete game state
//! - GameEvent: all possible inputs
//! - reduce(): state transition logic
//! - render(): diff-based framebuffer rendering
//!
//! Testable independently via ui_test.zig.

const state_lib = @import("ui_state");

// ============================================================================
// Constants
// ============================================================================

pub const BOARD_W = 10;
pub const BOARD_H = 20;
pub const CELL_SIZE: u16 = 11; // pixels per cell (10px + 1px gap)
pub const BOARD_X: u16 = 5; // board left offset
pub const BOARD_Y: u16 = 5; // board top offset
pub const INFO_X: u16 = BOARD_X + BOARD_W * CELL_SIZE + 8;

pub const FB = state_lib.Framebuffer(240, 240, .rgb565);

// RGB565 colors
pub const BLACK: u16 = 0x0000;
pub const WHITE: u16 = 0xFFFF;
pub const GRAY: u16 = 0x4208;
pub const DARK_GRAY: u16 = 0x2104;

pub const PIECE_COLORS = [7]u16{
    0x07FF, // I — cyan
    0x001F, // J — blue
    0xFD20, // L — orange
    0xFFE0, // O — yellow
    0x07E0, // S — green
    0xF81F, // T — purple
    0xF800, // Z — red
};

// ============================================================================
// Piece Definitions (4 rotations each, 4x4 bitmask)
// ============================================================================

pub const Piece = struct {
    shape: u3, // 0-6 → I,J,L,O,S,T,Z
    rot: u2, // 0-3
    x: i8,
    y: i8,
};

/// Each shape has 4 rotations, each rotation is 4 rows x 4 cols packed in u16.
/// Bit layout: row0[3:0] | row1[3:0] | row2[3:0] | row3[3:0]
pub const SHAPES = [7][4]u16{
    // I
    .{ 0x0F00, 0x2222, 0x00F0, 0x4444 },
    // J
    .{ 0x8E00, 0x6440, 0x0E20, 0x44C0 },
    // L
    .{ 0x2E00, 0x4460, 0x0E80, 0xC440 },
    // O
    .{ 0x6600, 0x6600, 0x6600, 0x6600 },
    // S
    .{ 0x6C00, 0x4620, 0x06C0, 0x8C40 },
    // T
    .{ 0x4E00, 0x4640, 0x0E40, 0x4C40 },
    // Z
    .{ 0xC600, 0x2640, 0x0C60, 0x4C80 },
};

pub fn getCell(shape: u16, row: u2, col: u2) bool {
    const bit: u4 = @as(u4, 3) - col;
    const shift: u4 = @as(u4, 3) - @as(u4, row);
    const total: u4 = shift * 4 + bit;
    return (shape >> total) & 1 != 0;
}

// ============================================================================
// State
// ============================================================================

pub const GamePhase = enum { playing, game_over };

pub const GameState = struct {
    board: [BOARD_H][BOARD_W]u8 = [_][BOARD_W]u8{[_]u8{0} ** BOARD_W} ** BOARD_H,
    piece: Piece = .{ .shape = 0, .rot = 0, .x = 3, .y = 0 },
    next_shape: u3 = 1,
    score: u32 = 0,
    lines: u32 = 0,
    level: u8 = 1,
    phase: GamePhase = .playing,
    tick_count: u32 = 0,
    rng_state: u32 = 12345,
};

pub const GameEvent = union(enum) {
    tick,
    move_left,
    move_right,
    rotate,
    soft_drop,
    hard_drop,
    restart,
};

pub const Store = state_lib.Store(GameState, GameEvent);

// ============================================================================
// Reducer
// ============================================================================

pub fn reduce(state: *GameState, event: GameEvent) void {
    switch (event) {
        .tick => {
            if (state.phase != .playing) return;
            state.tick_count += 1;
            const speed = @max(1, 30 / @as(u32, state.level));
            if (state.tick_count % speed != 0) return;
            if (!tryMove(state, 0, 1)) {
                lockPiece(state);
            }
        },
        .move_left => {
            if (state.phase != .playing) return;
            _ = tryMove(state, -1, 0);
        },
        .move_right => {
            if (state.phase != .playing) return;
            _ = tryMove(state, 1, 0);
        },
        .rotate => {
            if (state.phase != .playing) return;
            const old_rot = state.piece.rot;
            state.piece.rot +%= 1;
            if (collides(state)) {
                state.piece.rot = old_rot;
            }
        },
        .soft_drop => {
            if (state.phase != .playing) return;
            if (!tryMove(state, 0, 1)) {
                lockPiece(state);
            }
        },
        .hard_drop => {
            if (state.phase != .playing) return;
            while (tryMove(state, 0, 1)) {}
            lockPiece(state);
        },
        .restart => {
            const seed = state.rng_state;
            state.* = .{};
            state.rng_state = seed +% 1;
            state.next_shape = nextRng(state);
        },
    }
}

pub fn tryMove(state: *GameState, dx: i8, dy: i8) bool {
    state.piece.x += dx;
    state.piece.y += dy;
    if (collides(state)) {
        state.piece.x -= dx;
        state.piece.y -= dy;
        return false;
    }
    return true;
}

pub fn collides(state: *const GameState) bool {
    const shape = SHAPES[state.piece.shape][state.piece.rot];
    var row: u2 = 0;
    while (true) : (row += 1) {
        var col: u2 = 0;
        while (true) : (col += 1) {
            if (getCell(shape, row, col)) {
                const bx = @as(i16, state.piece.x) + col;
                const by = @as(i16, state.piece.y) + row;
                if (bx < 0 or bx >= BOARD_W or by >= BOARD_H) return true;
                if (by >= 0) {
                    if (state.board[@intCast(by)][@intCast(bx)] != 0) return true;
                }
            }
            if (col == 3) break;
        }
        if (row == 3) break;
    }
    return false;
}

pub fn lockPiece(state: *GameState) void {
    const shape = SHAPES[state.piece.shape][state.piece.rot];
    var row: u2 = 0;
    while (true) : (row += 1) {
        var col: u2 = 0;
        while (true) : (col += 1) {
            if (getCell(shape, row, col)) {
                const bx = @as(i16, state.piece.x) + col;
                const by = @as(i16, state.piece.y) + row;
                if (by >= 0 and by < BOARD_H and bx >= 0 and bx < BOARD_W) {
                    state.board[@intCast(by)][@intCast(bx)] = state.piece.shape + 1;
                }
            }
            if (col == 3) break;
        }
        if (row == 3) break;
    }

    // Clear lines
    var cleared: u32 = 0;
    var check_row: usize = BOARD_H;
    while (check_row > 0) {
        check_row -= 1;
        var full = true;
        for (0..BOARD_W) |c| {
            if (state.board[check_row][c] == 0) {
                full = false;
                break;
            }
        }
        if (full) {
            var shift: usize = check_row;
            while (shift > 0) : (shift -= 1) {
                state.board[shift] = state.board[shift - 1];
            }
            state.board[0] = [_]u8{0} ** BOARD_W;
            check_row += 1;
            cleared += 1;
        }
    }

    if (cleared > 0) {
        const points = [_]u32{ 0, 100, 300, 500, 800 };
        state.score += points[@min(cleared, 4)] * state.level;
        state.lines += cleared;
        state.level = @intCast(@min(20, state.lines / 10 + 1));
    }

    // Next piece
    state.piece = .{
        .shape = state.next_shape,
        .rot = 0,
        .x = 3,
        .y = 0,
    };
    state.next_shape = nextRng(state);

    if (collides(state)) {
        state.phase = .game_over;
    }
}

pub fn nextRng(state: *GameState) u3 {
    state.rng_state = state.rng_state *% 1103515245 +% 12345;
    return @intCast((state.rng_state >> 16) % 7);
}

// ============================================================================
// Render
// ============================================================================

/// Diff-render game state onto framebuffer.
/// Only redraws cells/UI that changed between state and prev.
pub fn render(fb: *FB, state: *const GameState, prev: *const GameState) void {
    // Board cells — diff render
    for (0..BOARD_H) |row| {
        for (0..BOARD_W) |col| {
            const cur = state.board[row][col];
            const old = prev.board[row][col];
            const cur_piece = isPieceAt(state, col, row);
            const old_piece = isPieceAt(prev, col, row);

            if (cur != old or cur_piece != old_piece) {
                const px: u16 = BOARD_X + @as(u16, @intCast(col)) * CELL_SIZE;
                const py: u16 = BOARD_Y + @as(u16, @intCast(row)) * CELL_SIZE;

                if (cur_piece) |shape| {
                    fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, PIECE_COLORS[shape]);
                } else if (cur > 0) {
                    fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, PIECE_COLORS[cur - 1]);
                } else {
                    fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, DARK_GRAY);
                }
            }
        }
    }

    // Score (only if changed)
    if (state.score != prev.score or state.phase != prev.phase) {
        fb.fillRect(INFO_X, 30, 100, 40, BLACK);
        drawNumber(fb, INFO_X, 30, state.score);
        drawNumber(fb, INFO_X, 46, state.lines);
    }

    // Level
    if (state.level != prev.level) {
        fb.fillRect(INFO_X, 70, 50, 16, BLACK);
        drawNumber(fb, INFO_X, 70, state.level);
    }

    // Next piece preview
    if (state.next_shape != prev.next_shape) {
        fb.fillRect(INFO_X, 100, 44, 44, BLACK);
        drawPiecePreview(fb, INFO_X, 100, state.next_shape);
    }

    // Game over overlay
    if (state.phase == .game_over and prev.phase != .game_over) {
        const board_w = BOARD_W * CELL_SIZE;
        const board_h = BOARD_H * CELL_SIZE;
        fb.fillRect(BOARD_X + 5, BOARD_Y + @as(u16, board_h / 2) - 10, @as(u16, board_w) - 10, 20, BLACK);
    }
}

pub fn isPieceAt(state: *const GameState, col: usize, row: usize) ?u3 {
    if (state.phase != .playing) return null;
    const shape = SHAPES[state.piece.shape][state.piece.rot];
    var pr: u2 = 0;
    while (true) : (pr += 1) {
        var pc: u2 = 0;
        while (true) : (pc += 1) {
            if (getCell(shape, pr, pc)) {
                const bx = @as(i16, state.piece.x) + pc;
                const by = @as(i16, state.piece.y) + pr;
                if (bx == @as(i16, @intCast(col)) and by == @as(i16, @intCast(row))) {
                    return state.piece.shape;
                }
            }
            if (pc == 3) break;
        }
        if (pr == 3) break;
    }
    return null;
}

pub fn drawPiecePreview(fb: *FB, x: u16, y: u16, shape: u3) void {
    const s = SHAPES[shape][0];
    var row: u2 = 0;
    while (true) : (row += 1) {
        var col: u2 = 0;
        while (true) : (col += 1) {
            const px = x + @as(u16, col) * CELL_SIZE;
            const py = y + @as(u16, row) * CELL_SIZE;
            if (getCell(s, row, col)) {
                fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, PIECE_COLORS[shape]);
            }
            if (col == 3) break;
        }
        if (row == 3) break;
    }
}

pub fn drawNumber(fb: *FB, x: u16, y: u16, value: u32) void {
    var buf: [10]u8 = undefined;
    const digits = formatDecimal(value, &buf);
    var cx = x;
    for (digits) |d| {
        drawDigit(fb, cx, y, d);
        cx += 6;
    }
}

pub fn formatDecimal(value: u32, buf: *[10]u8) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = value;
    var i: usize = 10;
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + v % 10);
    }
    return buf[i..10];
}

/// Minimal 5x7 digit bitmaps (packed, 1 byte per row)
pub const DIGIT_BITMAPS = [10][7]u8{
    .{ 0x70, 0x88, 0x98, 0xA8, 0xC8, 0x88, 0x70 }, // 0
    .{ 0x20, 0x60, 0x20, 0x20, 0x20, 0x20, 0x70 }, // 1
    .{ 0x70, 0x88, 0x08, 0x10, 0x20, 0x40, 0xF8 }, // 2
    .{ 0x70, 0x88, 0x08, 0x30, 0x08, 0x88, 0x70 }, // 3
    .{ 0x10, 0x30, 0x50, 0x90, 0xF8, 0x10, 0x10 }, // 4
    .{ 0xF8, 0x80, 0xF0, 0x08, 0x08, 0x88, 0x70 }, // 5
    .{ 0x30, 0x40, 0x80, 0xF0, 0x88, 0x88, 0x70 }, // 6
    .{ 0xF8, 0x08, 0x10, 0x20, 0x40, 0x40, 0x40 }, // 7
    .{ 0x70, 0x88, 0x88, 0x70, 0x88, 0x88, 0x70 }, // 8
    .{ 0x70, 0x88, 0x88, 0x78, 0x08, 0x10, 0x60 }, // 9
};

pub fn drawDigit(fb: *FB, x: u16, y: u16, char: u8) void {
    if (char < '0' or char > '9') return;
    const bitmap = &DIGIT_BITMAPS[char - '0'];
    for (0..7) |row| {
        for (0..5) |col| {
            const bit = @as(u8, 0x80) >> @intCast(col);
            if (bitmap[row] & bit != 0) {
                fb.setPixel(x + @as(u16, @intCast(col)), y + @as(u16, @intCast(row)), WHITE);
            }
        }
    }
}

/// Draw the initial static elements (grid outline, labels).
pub fn drawStatic(fb: *FB) void {
    const board_w: u16 = BOARD_W * CELL_SIZE;
    const board_h: u16 = BOARD_H * CELL_SIZE;
    fb.fillRect(BOARD_X, BOARD_Y, board_w, board_h, DARK_GRAY);
    fb.drawRect(BOARD_X -| 1, BOARD_Y -| 1, board_w + 2, board_h + 2, GRAY, 1);
    fb.hline(INFO_X, 20, 50, GRAY);
    fb.hline(INFO_X, 60, 50, GRAY);
    fb.hline(INFO_X, 90, 50, GRAY);
}
