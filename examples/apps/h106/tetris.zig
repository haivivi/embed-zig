//! Tetris sub-module — reusable game logic for embedding in H106 app.
//! Adapted from examples/apps/tetris/ui.zig.

const state_lib = @import("ui_state");
pub const FB = state_lib.Framebuffer(240, 240, .rgb565);

pub const BOARD_W = 10;
pub const BOARD_H = 20;
pub const CELL_SIZE: u16 = 11;
pub const BOARD_X: u16 = 5;
pub const BOARD_Y: u16 = 5;
pub const INFO_X: u16 = BOARD_X + BOARD_W * CELL_SIZE + 8;

const BLACK: u16 = 0x0000;
const WHITE: u16 = 0xFFFF;
const DARK_GRAY: u16 = 0x2104;
const GRAY: u16 = 0x4208;

const PIECE_COLORS = [7]u16{ 0x07FF, 0x001F, 0xFD20, 0xFFE0, 0x07E0, 0xF81F, 0xF800 };

const Piece = struct { shape: u3, rot: u2, x: i8, y: i8 };

const SHAPES = [7][4]u16{
    .{ 0x0F00, 0x2222, 0x00F0, 0x4444 },
    .{ 0x8E00, 0x6440, 0x0E20, 0x44C0 },
    .{ 0x2E00, 0x4460, 0x0E80, 0xC440 },
    .{ 0x6600, 0x6600, 0x6600, 0x6600 },
    .{ 0x6C00, 0x4620, 0x06C0, 0x8C40 },
    .{ 0x4E00, 0x4640, 0x0E40, 0x4C40 },
    .{ 0xC600, 0x2640, 0x0C60, 0x4C80 },
};

fn getCell(shape: u16, row: u2, col: u2) bool {
    const bit: u4 = @as(u4, 3) - col;
    const shift: u4 = @as(u4, 3) - @as(u4, row);
    const total: u4 = shift * 4 + bit;
    return (shape >> total) & 1 != 0;
}

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

pub const GameEvent = union(enum) { tick, move_left, move_right, rotate, soft_drop, hard_drop, restart };

pub fn reduce(state: *GameState, event: GameEvent) void {
    switch (event) {
        .tick => {
            if (state.phase != .playing) return;
            state.tick_count += 1;
            const speed = @max(1, 30 / @as(u32, state.level));
            if (state.tick_count % speed != 0) return;
            if (!tryMove(state, 0, 1)) lockPiece(state);
        },
        .move_left => { if (state.phase == .playing) _ = tryMove(state, -1, 0); },
        .move_right => { if (state.phase == .playing) _ = tryMove(state, 1, 0); },
        .rotate => {
            if (state.phase != .playing) return;
            const old = state.piece.rot;
            state.piece.rot +%= 1;
            if (collides(state)) state.piece.rot = old;
        },
        .soft_drop => { if (state.phase == .playing) { if (!tryMove(state, 0, 1)) lockPiece(state); } },
        .hard_drop => {
            if (state.phase != .playing) return;
            while (tryMove(state, 0, 1)) {}
            lockPiece(state);
        },
        .restart => {
            const seed = state.rng_state +% 1;
            state.* = .{};
            state.rng_state = seed;
            state.next_shape = nextRng(state);
        },
    }
}

fn tryMove(s: *GameState, dx: i8, dy: i8) bool {
    s.piece.x += dx; s.piece.y += dy;
    if (collides(s)) { s.piece.x -= dx; s.piece.y -= dy; return false; }
    return true;
}

fn collides(s: *const GameState) bool {
    const shape = SHAPES[s.piece.shape][s.piece.rot];
    var row: u2 = 0;
    while (true) : (row += 1) {
        var col: u2 = 0;
        while (true) : (col += 1) {
            if (getCell(shape, row, col)) {
                const bx = @as(i16, s.piece.x) + col;
                const by = @as(i16, s.piece.y) + row;
                if (bx < 0 or bx >= BOARD_W or by >= BOARD_H) return true;
                if (by >= 0 and s.board[@intCast(by)][@intCast(bx)] != 0) return true;
            }
            if (col == 3) break;
        }
        if (row == 3) break;
    }
    return false;
}

fn lockPiece(s: *GameState) void {
    const shape = SHAPES[s.piece.shape][s.piece.rot];
    var row: u2 = 0;
    while (true) : (row += 1) {
        var col: u2 = 0;
        while (true) : (col += 1) {
            if (getCell(shape, row, col)) {
                const bx = @as(i16, s.piece.x) + col;
                const by = @as(i16, s.piece.y) + row;
                if (by >= 0 and by < BOARD_H and bx >= 0 and bx < BOARD_W)
                    s.board[@intCast(by)][@intCast(bx)] = s.piece.shape + 1;
            }
            if (col == 3) break;
        }
        if (row == 3) break;
    }
    var cleared: u32 = 0;
    var cr: usize = BOARD_H;
    while (cr > 0) { cr -= 1;
        var full = true;
        for (0..BOARD_W) |c| { if (s.board[cr][c] == 0) { full = false; break; } }
        if (full) { var sh: usize = cr; while (sh > 0) : (sh -= 1) s.board[sh] = s.board[sh - 1];
            s.board[0] = [_]u8{0} ** BOARD_W; cr += 1; cleared += 1; }
    }
    if (cleared > 0) {
        const pts = [_]u32{ 0, 100, 300, 500, 800 };
        s.score += pts[@min(cleared, 4)] * s.level;
        s.lines += cleared;
        s.level = @intCast(@min(20, s.lines / 10 + 1));
    }
    s.piece = .{ .shape = s.next_shape, .rot = 0, .x = 3, .y = 0 };
    s.next_shape = nextRng(s);
    if (collides(s)) s.phase = .game_over;
}

fn nextRng(s: *GameState) u3 {
    s.rng_state = s.rng_state *% 1103515245 +% 12345;
    return @intCast((s.rng_state >> 16) % 7);
}

pub fn render(fb: *FB, state: *const GameState, prev: *const GameState) void {
    // Board background
    fb.fillRect(BOARD_X, BOARD_Y, BOARD_W * CELL_SIZE, BOARD_H * CELL_SIZE, DARK_GRAY);
    fb.drawRect(BOARD_X -| 1, BOARD_Y -| 1, BOARD_W * CELL_SIZE + 2, BOARD_H * CELL_SIZE + 2, GRAY, 1);
    // Cells
    for (0..BOARD_H) |row| {
        for (0..BOARD_W) |col| {
            const cur = state.board[row][col];
            const cur_piece = isPieceAt(state, col, row);
            const px: u16 = BOARD_X + @as(u16, @intCast(col)) * CELL_SIZE;
            const py: u16 = BOARD_Y + @as(u16, @intCast(row)) * CELL_SIZE;
            if (cur_piece) |sh| {
                fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, PIECE_COLORS[sh]);
            } else if (cur > 0) {
                fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, PIECE_COLORS[cur - 1]);
            }
        }
    }
    _ = prev;
    // Score
    fb.fillRect(INFO_X, 30, 100, 10, BLACK);
    drawNum(fb, INFO_X, 30, state.score);
}

fn isPieceAt(s: *const GameState, col: usize, row: usize) ?u3 {
    if (s.phase != .playing) return null;
    const shape = SHAPES[s.piece.shape][s.piece.rot];
    var pr: u2 = 0;
    while (true) : (pr += 1) {
        var pc: u2 = 0;
        while (true) : (pc += 1) {
            if (getCell(shape, pr, pc)) {
                if (@as(i16, s.piece.x) + pc == @as(i16, @intCast(col)) and
                    @as(i16, s.piece.y) + pr == @as(i16, @intCast(row)))
                    return s.piece.shape;
            }
            if (pc == 3) break;
        }
        if (pr == 3) break;
    }
    return null;
}

const DIGIT_BMP = [10][7]u8{
    .{0x70,0x88,0x98,0xA8,0xC8,0x88,0x70},.{0x20,0x60,0x20,0x20,0x20,0x20,0x70},
    .{0x70,0x88,0x08,0x10,0x20,0x40,0xF8},.{0x70,0x88,0x08,0x30,0x08,0x88,0x70},
    .{0x10,0x30,0x50,0x90,0xF8,0x10,0x10},.{0xF8,0x80,0xF0,0x08,0x08,0x88,0x70},
    .{0x30,0x40,0x80,0xF0,0x88,0x88,0x70},.{0xF8,0x08,0x10,0x20,0x40,0x40,0x40},
    .{0x70,0x88,0x88,0x70,0x88,0x88,0x70},.{0x70,0x88,0x88,0x78,0x08,0x10,0x60},
};

fn drawNum(fb: *FB, x: u16, y: u16, val: u32) void {
    var buf: [10]u8 = undefined;
    var v = val; var i: usize = 10;
    if (v == 0) { buf[9] = '0'; i = 9; }
    else while (v > 0) : (v /= 10) { i -= 1; buf[i] = @intCast('0' + v % 10); }
    var cx = x;
    for (buf[i..10]) |ch| {
        if (ch >= '0' and ch <= '9') {
            const bmp = &DIGIT_BMP[ch - '0'];
            for (0..7) |r| for (0..5) |c| {
                if (bmp[r] & (@as(u8, 0x80) >> @intCast(c)) != 0)
                    fb.setPixel(cx + @as(u16, @intCast(c)), y + @as(u16, @intCast(r)), WHITE);
            };
        }
        cx += 6;
    }
}
