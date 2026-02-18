//! Tetris — Framebuffer Renderer
//!
//! Diff-based rendering: only redraws cells/UI that changed between frames.

const state_lib = @import("ui_state");
const game = @import("state/tetris.zig");

pub const CELL_SIZE: u16 = 11;
pub const BOARD_X: u16 = 5;
pub const BOARD_Y: u16 = 5;
pub const INFO_X: u16 = BOARD_X + game.BOARD_W * CELL_SIZE + 8;

pub const FB = state_lib.Framebuffer(240, 240, .rgb565);

pub const BLACK: u16 = 0x0000;
pub const WHITE: u16 = 0xFFFF;
pub const GRAY: u16 = 0x4208;
pub const DARK_GRAY: u16 = 0x2104;

// Re-export state types for app.zig and tests
pub const GameState = game.GameState;
pub const GameEvent = game.GameEvent;
pub const GamePhase = game.GamePhase;
pub const Piece = game.Piece;
pub const reduce = game.reduce;
pub const Store = state_lib.Store(GameState, GameEvent);

pub const BOARD_W = game.BOARD_W;
pub const BOARD_H = game.BOARD_H;
pub const PIECE_COLORS = game.PIECE_COLORS;
pub const SHAPES = game.SHAPES;
pub const getCell = game.getCell;
pub const isPieceAt = game.isPieceAt;
pub const collides = game.collides;
pub const tryMove = game.tryMove;

pub fn render(fb: *FB, state: *const GameState, prev: *const GameState) void {
    for (0..game.BOARD_H) |row| {
        for (0..game.BOARD_W) |col| {
            const cur = state.board[row][col];
            const old = prev.board[row][col];
            const cur_piece = game.isPieceAt(state, col, row);
            const old_piece = game.isPieceAt(prev, col, row);

            if (cur != old or cur_piece != old_piece) {
                const px: u16 = BOARD_X + @as(u16, @intCast(col)) * CELL_SIZE;
                const py: u16 = BOARD_Y + @as(u16, @intCast(row)) * CELL_SIZE;

                if (cur_piece) |shape| {
                    fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, game.PIECE_COLORS[shape]);
                } else if (cur > 0) {
                    fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, game.PIECE_COLORS[cur - 1]);
                } else {
                    fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, DARK_GRAY);
                }
            }
        }
    }

    if (state.score != prev.score or state.phase != prev.phase) {
        fb.fillRect(INFO_X, 30, 100, 40, BLACK);
        drawNumber(fb, INFO_X, 30, state.score);
        drawNumber(fb, INFO_X, 46, state.lines);
    }

    if (state.level != prev.level) {
        fb.fillRect(INFO_X, 70, 50, 16, BLACK);
        drawNumber(fb, INFO_X, 70, state.level);
    }

    if (state.next_shape != prev.next_shape) {
        fb.fillRect(INFO_X, 100, 44, 44, BLACK);
        drawPiecePreview(fb, INFO_X, 100, state.next_shape);
    }

    if (state.phase == .game_over and prev.phase != .game_over) {
        const board_w = game.BOARD_W * CELL_SIZE;
        const board_h = game.BOARD_H * CELL_SIZE;
        fb.fillRect(BOARD_X + 5, BOARD_Y + @as(u16, board_h / 2) - 10, @as(u16, board_w) - 10, 20, BLACK);
    }
}

pub fn drawPiecePreview(fb: *FB, x: u16, y: u16, shape: u3) void {
    const s = game.SHAPES[shape][0];
    var row: u2 = 0;
    while (true) : (row += 1) {
        var col: u2 = 0;
        while (true) : (col += 1) {
            const px = x + @as(u16, col) * CELL_SIZE;
            const py = y + @as(u16, row) * CELL_SIZE;
            if (game.getCell(s, row, col)) {
                fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, game.PIECE_COLORS[shape]);
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
    if (value == 0) { buf[0] = '0'; return buf[0..1]; }
    var v = value;
    var i: usize = 10;
    while (v > 0) : (v /= 10) { i -= 1; buf[i] = @intCast('0' + v % 10); }
    return buf[i..10];
}

pub const DIGIT_BITMAPS = [10][7]u8{
    .{ 0x70, 0x88, 0x98, 0xA8, 0xC8, 0x88, 0x70 },
    .{ 0x20, 0x60, 0x20, 0x20, 0x20, 0x20, 0x70 },
    .{ 0x70, 0x88, 0x08, 0x10, 0x20, 0x40, 0xF8 },
    .{ 0x70, 0x88, 0x08, 0x30, 0x08, 0x88, 0x70 },
    .{ 0x10, 0x30, 0x50, 0x90, 0xF8, 0x10, 0x10 },
    .{ 0xF8, 0x80, 0xF0, 0x08, 0x08, 0x88, 0x70 },
    .{ 0x30, 0x40, 0x80, 0xF0, 0x88, 0x88, 0x70 },
    .{ 0xF8, 0x08, 0x10, 0x20, 0x40, 0x40, 0x40 },
    .{ 0x70, 0x88, 0x88, 0x70, 0x88, 0x88, 0x70 },
    .{ 0x70, 0x88, 0x88, 0x78, 0x08, 0x10, 0x60 },
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

pub fn drawStatic(fb: *FB) void {
    const board_w: u16 = game.BOARD_W * CELL_SIZE;
    const board_h: u16 = game.BOARD_H * CELL_SIZE;
    fb.fillRect(BOARD_X, BOARD_Y, board_w, board_h, DARK_GRAY);
    fb.drawRect(BOARD_X -| 1, BOARD_Y -| 1, board_w + 2, board_h + 2, GRAY, 1);
    fb.hline(INFO_X, 20, 50, GRAY);
    fb.hline(INFO_X, 60, 50, GRAY);
    fb.hline(INFO_X, 90, 50, GRAY);
}
