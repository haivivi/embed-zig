//! Games — Framebuffer Render Dispatcher

const ui_state = @import("ui_state");
const app_state = @import("../state/app.zig");
const tetris_state = @import("../state/tetris.zig");
const racer_state = @import("../state/racer.zig");

pub const FB = ui_state.Framebuffer(240, 240, .rgb565);
pub const Store = ui_state.Store(app_state.AppState, app_state.AppEvent);

const BLACK: u16 = 0x0000;
const WHITE: u16 = 0xFFFF;
const GRAY: u16 = 0x4208;
const DARK_GRAY: u16 = 0x2104;
const ACCENT: u16 = 0xFD20;

pub fn render(fb: *FB, state: *const app_state.AppState, prev: *const app_state.AppState) void {
    if (state.page != prev.page) {
        fb.clear(BLACK);
        renderFull(fb, state);
        return;
    }
    switch (state.page) {
        .menu => renderMenu(fb, state, prev),
        .playing => renderGame(fb, state, prev),
    }
}

pub fn renderFull(fb: *FB, state: *const app_state.AppState) void {
    switch (state.page) {
        .menu => renderMenuFull(fb, state),
        .playing => {
            switch (state.current_game) {
                .tetris => {
                    drawTetrisStatic(fb);
                    const empty = tetris_state.GameState{};
                    renderTetris(fb, &state.tetris, &empty);
                },
                .racer => {
                    const empty = racer_state.GameState{};
                    renderRacer(fb, &state.racer, &empty);
                },
            }
        },
    }
}

// ============================================================================
// Menu — horizontal slider
// ============================================================================

const game_names = [2][]const u8{ "TETRIS", "RACER" };
const game_colors = [2]u16{ 0x07FF, 0xF800 };

fn renderMenuFull(fb: *FB, state: *const app_state.AppState) void {
    fb.fillRect(0, 0, 240, 240, BLACK);

    // Title
    drawText(fb, 80, 30, "GAMES", WHITE);

    // Two game cards side by side
    for (0..2) |i| {
        const x: u16 = 20 + @as(u16, @intCast(i)) * 110;
        const selected = (i == state.selected);
        const bg: u16 = if (selected) 0x2945 else 0x1082;
        fb.fillRoundRect(x, 80, 100, 120, 10, bg);
        fb.fillRoundRect(x + 20, 100, 60, 60, 8, game_colors[i]);
        if (selected) fb.drawRect(x, 80, 100, 120, ACCENT, 2);

        drawText(fb, x + 20, 175, game_names[i], if (selected) WHITE else GRAY);
    }

    // Hint
    drawText(fb, 60, 220, "< SELECT >", GRAY);
}

fn renderMenu(fb: *FB, state: *const app_state.AppState, prev: *const app_state.AppState) void {
    if (state.selected != prev.selected) {
        renderMenuFull(fb, state);
    }
}

// ============================================================================
// Tetris render (from tetris/ui.zig)
// ============================================================================

const CELL_SIZE: u16 = 11;
const BOARD_X: u16 = 5;
const BOARD_Y: u16 = 5;
const INFO_X: u16 = BOARD_X + tetris_state.BOARD_W * CELL_SIZE + 8;

fn drawTetrisStatic(fb: *FB) void {
    const board_w: u16 = tetris_state.BOARD_W * CELL_SIZE;
    const board_h: u16 = tetris_state.BOARD_H * CELL_SIZE;
    fb.fillRect(BOARD_X, BOARD_Y, board_w, board_h, DARK_GRAY);
    fb.drawRect(BOARD_X -| 1, BOARD_Y -| 1, board_w + 2, board_h + 2, GRAY, 1);
    fb.hline(INFO_X, 20, 50, GRAY);
    fb.hline(INFO_X, 60, 50, GRAY);
    fb.hline(INFO_X, 90, 50, GRAY);
}

fn renderTetris(fb: *FB, state: *const tetris_state.GameState, prev: *const tetris_state.GameState) void {
    for (0..tetris_state.BOARD_H) |row| {
        for (0..tetris_state.BOARD_W) |col| {
            const cur = state.board[row][col];
            const old = prev.board[row][col];
            const cur_piece = tetris_state.isPieceAt(state, col, row);
            const old_piece = tetris_state.isPieceAt(prev, col, row);
            if (cur != old or cur_piece != old_piece) {
                const px: u16 = BOARD_X + @as(u16, @intCast(col)) * CELL_SIZE;
                const py: u16 = BOARD_Y + @as(u16, @intCast(row)) * CELL_SIZE;
                if (cur_piece) |shape| {
                    fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, tetris_state.PIECE_COLORS[shape]);
                } else if (cur > 0) {
                    fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, tetris_state.PIECE_COLORS[cur - 1]);
                } else {
                    fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, DARK_GRAY);
                }
            }
        }
    }
    if (state.score != prev.score or state.phase != prev.phase) {
        fb.fillRect(INFO_X, 30, 100, 40, BLACK);
        drawNum(fb, INFO_X, 30, state.score);
        drawNum(fb, INFO_X, 46, state.lines);
    }
    if (state.level != prev.level) {
        fb.fillRect(INFO_X, 70, 50, 16, BLACK);
        drawNum(fb, INFO_X, 70, state.level);
    }
    if (state.next_shape != prev.next_shape) {
        fb.fillRect(INFO_X, 100, 44, 44, BLACK);
        const s = tetris_state.SHAPES[state.next_shape][0];
        var row: u2 = 0;
        while (true) : (row += 1) {
            var col: u2 = 0;
            while (true) : (col += 1) {
                if (tetris_state.getCell(s, row, col)) {
                    fb.fillRect(INFO_X + @as(u16, col) * CELL_SIZE, 100 + @as(u16, row) * CELL_SIZE, CELL_SIZE - 1, CELL_SIZE - 1, tetris_state.PIECE_COLORS[state.next_shape]);
                }
                if (col == 3) break;
            }
            if (row == 3) break;
        }
    }
    if (state.phase == .game_over and prev.phase != .game_over) {
        fb.fillRect(BOARD_X + 5, BOARD_Y + 100, 100, 20, BLACK);
        drawText(fb, BOARD_X + 15, BOARD_Y + 103, "GAME OVER", WHITE);
    }
}

// ============================================================================
// Racer render
// ============================================================================

const ROAD_COLOR: u16 = 0x3186;
const GRASS_COLOR: u16 = 0x2C04;
const MARK_COLOR: u16 = 0xC618;
const PLAYER_COLOR: u16 = 0xF800;
const PLAYER_WIND: u16 = 0xFBE0;

fn renderRacer(fb: *FB, state: *const racer_state.GameState, prev: *const racer_state.GameState) void {
    _ = prev;
    // Full redraw each frame (racer scrolls every tick)
    fb.fillRect(0, 0, 240, 240, GRASS_COLOR);
    fb.fillRect(racer_state.ROAD_LEFT, 0, racer_state.ROAD_W, 240, ROAD_COLOR);

    // Road markings
    const off = state.scroll_offset;
    var my: i16 = -@as(i16, racer_state.MARK_H);
    while (my < 240) : (my += @intCast(racer_state.MARK_H + racer_state.MARK_GAP)) {
        const dy: i16 = my + @as(i16, @intCast(off));
        if (dy >= 0 and dy < 240) {
            const uy: u16 = @intCast(dy);
            fb.fillRect(racer_state.ROAD_LEFT + racer_state.LANE_W - 1, uy, racer_state.MARK_W, racer_state.MARK_H, MARK_COLOR);
            fb.fillRect(racer_state.ROAD_LEFT + 2 * racer_state.LANE_W - 1, uy, racer_state.MARK_W, racer_state.MARK_H, MARK_COLOR);
        }
    }

    // Obstacles
    for (state.obstacles) |obs| {
        if (!obs.active) continue;
        if (obs.y < 0 or obs.y >= 240) continue;
        const ox = racer_state.LANE_X[obs.lane];
        fb.fillRoundRect(ox, @intCast(obs.y), racer_state.OBS_W, racer_state.OBS_H, 4, racer_state.OBS_COLORS[obs.color_idx]);
    }

    // Player car
    fb.fillRoundRect(state.player_x, racer_state.CAR_Y, racer_state.CAR_W, racer_state.CAR_H, 4, PLAYER_COLOR);
    fb.fillRect(state.player_x + 4, racer_state.CAR_Y + 4, racer_state.CAR_W - 8, 8, PLAYER_WIND);

    // HUD
    fb.fillRect(0, 0, 240, 16, BLACK);
    drawNum(fb, 4, 4, state.score);

    if (state.phase == .game_over) {
        fb.fillRect(50, 100, 140, 30, BLACK);
        drawText(fb, 65, 107, "GAME OVER", WHITE);
    }
}

// ============================================================================
// Game dispatcher
// ============================================================================

fn renderGame(fb: *FB, state: *const app_state.AppState, prev: *const app_state.AppState) void {
    switch (state.current_game) {
        .tetris => renderTetris(fb, &state.tetris, &prev.tetris),
        .racer => renderRacer(fb, &state.racer, &prev.racer),
    }
}

// ============================================================================
// Minimal text/number drawing (5x7 digit bitmaps)
// ============================================================================

const DIGIT_BITMAPS = [10][7]u8{
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

fn drawNum(fb: *FB, x: u16, y: u16, value: u32) void {
    var buf: [10]u8 = undefined;
    var v = value;
    if (v == 0) { buf[9] = '0'; drawDigitRow(fb, x, y, buf[9..10]); return; }
    var i: usize = 10;
    while (v > 0) : (v /= 10) { i -= 1; buf[i] = @intCast('0' + v % 10); }
    drawDigitRow(fb, x, y, buf[i..10]);
}

fn drawDigitRow(fb: *FB, x: u16, y: u16, digits: []const u8) void {
    var cx = x;
    for (digits) |d| {
        if (d >= '0' and d <= '9') {
            const bmp = &DIGIT_BITMAPS[d - '0'];
            for (0..7) |row| {
                for (0..5) |col| {
                    if (bmp[row] & (@as(u8, 0x80) >> @intCast(col)) != 0) {
                        fb.setPixel(cx + @as(u16, @intCast(col)), y + @as(u16, @intCast(row)), WHITE);
                    }
                }
            }
        }
        cx += 6;
    }
}

fn drawText(fb: *FB, x: u16, y: u16, text: []const u8, color: u16) void {
    var cx = x;
    for (text) |ch| {
        if (ch >= '!' and ch <= '~') {
            // Simple 1px-wide vertical bars for letter shapes (crude but visible)
            fb.fillRect(cx, y, 5, 7, color);
            fb.setPixel(cx + 1, y + 1, BLACK);
            fb.setPixel(cx + 3, y + 1, BLACK);
            fb.setPixel(cx + 1, y + 5, BLACK);
            fb.setPixel(cx + 3, y + 5, BLACK);
        }
        cx += 6;
    }
}
