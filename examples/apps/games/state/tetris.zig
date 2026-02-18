//! Tetris — Game State + Reducer
//!
//! Pure game logic, no rendering dependencies.
//! Shared by both Framebuffer and LVGL renderers.

// ============================================================================
// Constants
// ============================================================================

pub const BOARD_W = 10;
pub const BOARD_H = 20;

// RGB565 colors (used by renderers)
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
// Piece Definitions
// ============================================================================

pub const Piece = struct {
    shape: u3,
    rot: u2,
    x: i8,
    y: i8,
};

pub const SHAPES = [7][4]u16{
    .{ 0x0F00, 0x2222, 0x00F0, 0x4444 }, // I
    .{ 0x8E00, 0x6440, 0x0E20, 0x44C0 }, // J
    .{ 0x2E00, 0x4460, 0x0E80, 0xC440 }, // L
    .{ 0x6600, 0x6600, 0x6600, 0x6600 }, // O
    .{ 0x6C00, 0x4620, 0x06C0, 0x8C40 }, // S
    .{ 0x4E00, 0x4640, 0x0E40, 0x4C40 }, // T
    .{ 0xC600, 0x2640, 0x0C60, 0x4C80 }, // Z
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
            if (!tryMove(state, 0, 1)) lockPiece(state);
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
            if (collides(state)) state.piece.rot = old_rot;
        },
        .soft_drop => {
            if (state.phase != .playing) return;
            if (!tryMove(state, 0, 1)) lockPiece(state);
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

    var cleared: u32 = 0;
    var check_row: usize = BOARD_H;
    while (check_row > 0) {
        check_row -= 1;
        var full = true;
        for (0..BOARD_W) |c| {
            if (state.board[check_row][c] == 0) { full = false; break; }
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

    state.piece = .{ .shape = state.next_shape, .rot = 0, .x = 3, .y = 0 };
    state.next_shape = nextRng(state);
    if (collides(state)) state.phase = .game_over;
}

pub fn nextRng(state: *GameState) u3 {
    state.rng_state = state.rng_state *% 1103515245 +% 12345;
    return @intCast((state.rng_state >> 16) % 7);
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
