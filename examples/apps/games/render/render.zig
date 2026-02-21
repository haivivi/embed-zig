//! Games — Framebuffer Render Dispatcher

const ui_state = @import("ui_state");
const flux = @import("flux");
const app_state = @import("../state/app.zig");
const tetris_state = @import("../state/tetris.zig");
const racer_state = @import("../state/racer.zig");

pub const FB = ui_state.Framebuffer(240, 240, .rgb565);
pub const Store = flux.Store(app_state.AppState, app_state.AppEvent);
const TtfFont = ui_state.TtfFont;

// Fonts (set by app.zig)
pub var font_text: ?*TtfFont = null;
pub var font_icon: ?*TtfFont = null;

// Phosphor icon codepoints (UTF-8 encoded)
const ICON_TETRIS = "\xee\x91\xa4"; // U+E464 squares-four
const ICON_RACER = "\xee\xa3\x8c"; // U+E8CC car-profile

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
                    renderTetrisFull(fb, &state.tetris);
                },
                .racer => {
                    renderRacerFull(fb, &state.racer);
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

    if (font_text) |f| {
        const title = "GAMES";
        const tw = f.textWidth(title);
        fb.drawTextTtf((240 -| tw) / 2, 20, title, f, WHITE);
    }

    for (0..2) |i| renderMenuCard(fb, i, i == state.selected);

    if (font_text) |f| {
        const hint = "< SELECT >";
        const tw = f.textWidth(hint);
        fb.drawTextTtf((240 -| tw) / 2, 218, hint, f, GRAY);
    }
}

fn renderMenuCard(fb: *FB, idx: usize, selected: bool) void {
    const icons = [2][]const u8{ ICON_TETRIS, ICON_RACER };
    const x: u16 = 20 + @as(u16, @intCast(idx)) * 110;
    const bg: u16 = if (selected) 0x2945 else 0x1082;
    fb.fillRoundRect(x, 70, 100, 130, 10, bg);

    if (font_icon) |f| {
        fb.drawTextTtf(x + 26, 80, icons[idx], f, game_colors[idx]);
    } else {
        fb.fillRoundRect(x + 20, 85, 60, 60, 8, game_colors[idx]);
    }

    if (font_text) |f| {
        const tw = f.textWidth(game_names[idx]);
        fb.drawTextTtf(x + (100 -| tw) / 2, 165, game_names[idx], f, if (selected) WHITE else GRAY);
    }

    if (selected) fb.drawRect(x, 70, 100, 130, ACCENT, 2);
}

fn renderMenu(fb: *FB, state: *const app_state.AppState, prev: *const app_state.AppState) void {
    if (state.selected != prev.selected) {
        renderMenuCard(fb, prev.selected, false);
        renderMenuCard(fb, state.selected, true);
    }
}

// ============================================================================
// Tetris render
// ============================================================================

fn renderTetrisFull(fb: *FB, state: *const tetris_state.GameState) void {
    for (0..tetris_state.BOARD_H) |row| {
        for (0..tetris_state.BOARD_W) |col| {
            const px: u16 = BOARD_X + @as(u16, @intCast(col)) * CELL_SIZE;
            const py: u16 = BOARD_Y + @as(u16, @intCast(row)) * CELL_SIZE;
            const piece_at = tetris_state.isPieceAt(state, col, row);
            const cell = state.board[row][col];
            if (piece_at) |shape| {
                fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, tetris_state.PIECE_COLORS[shape]);
            } else if (cell > 0) {
                fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, tetris_state.PIECE_COLORS[cell - 1]);
            } else {
                fb.fillRect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, DARK_GRAY);
            }
        }
    }
    // HUD
    fb.fillRect(INFO_X, 20, 110, 50, BLACK);
    if (font_text) |f| {
        var buf: [10]u8 = undefined;
        fb.drawTextTtf(INFO_X, 22, fmtDec(&buf, state.score), f, WHITE);
        fb.drawTextTtf(INFO_X, 40, fmtDec(&buf, state.lines), f, GRAY);
    } else {
        drawNum(fb, INFO_X, 30, state.score);
        drawNum(fb, INFO_X, 46, state.lines);
    }
    fb.fillRect(INFO_X, 70, 60, 16, BLACK);
    if (font_text) |f| {
        var buf: [10]u8 = undefined;
        fb.drawTextTtf(INFO_X, 70, fmtDec(&buf, state.level), f, WHITE);
    } else {
        drawNum(fb, INFO_X, 70, state.level);
    }
    // Next piece
    fb.fillRect(INFO_X, 100, 44, 44, BLACK);
    const s = tetris_state.SHAPES[state.next_shape][0];
    var r: u2 = 0;
    while (true) : (r += 1) {
        var co: u2 = 0;
        while (true) : (co += 1) {
            if (tetris_state.getCell(s, r, co)) {
                fb.fillRect(INFO_X + @as(u16, co) * CELL_SIZE, 100 + @as(u16, r) * CELL_SIZE, CELL_SIZE - 1, CELL_SIZE - 1, tetris_state.PIECE_COLORS[state.next_shape]);
            }
            if (co == 3) break;
        }
        if (r == 3) break;
    }
}

fn renderRacerFull(fb: *FB, state: *const racer_state.GameState) void {
    const empty = racer_state.GameState{};
    renderRacer(fb, state, &empty);
}

const CELL_SIZE: u16 = 11;
const BOARD_X: u16 = 5;
const BOARD_Y: u16 = 5;
const INFO_X: u16 = BOARD_X + tetris_state.BOARD_W * CELL_SIZE + 8;

fn drawTetrisStatic(fb: *FB) void {
    const board_w: u16 = tetris_state.BOARD_W * CELL_SIZE;
    const board_h: u16 = tetris_state.BOARD_H * CELL_SIZE;
    fb.fillRect(BOARD_X, BOARD_Y, board_w, board_h, DARK_GRAY);
    fb.drawRect(BOARD_X -| 1, BOARD_Y -| 1, board_w + 2, board_h + 2, GRAY, 1);
    if (font_text) |f| {
        fb.drawTextTtf(INFO_X, 6, "SCORE", f, GRAY);
        fb.drawTextTtf(INFO_X, 56, "LEVEL", f, GRAY);
        fb.drawTextTtf(INFO_X, 86, "NEXT", f, GRAY);
    } else {
        fb.hline(INFO_X, 20, 50, GRAY);
        fb.hline(INFO_X, 60, 50, GRAY);
        fb.hline(INFO_X, 90, 50, GRAY);
    }
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
        fb.fillRect(INFO_X, 20, 110, 50, BLACK);
        if (font_text) |f| {
            var buf: [10]u8 = undefined;
            fb.drawTextTtf(INFO_X, 22, fmtDec(&buf, state.score), f, WHITE);
            fb.drawTextTtf(INFO_X, 40, fmtDec(&buf, state.lines), f, GRAY);
        } else {
            drawNum(fb, INFO_X, 30, state.score);
            drawNum(fb, INFO_X, 46, state.lines);
        }
    }
    if (state.level != prev.level) {
        fb.fillRect(INFO_X, 70, 60, 16, BLACK);
        if (font_text) |f| {
            var buf: [10]u8 = undefined;
            fb.drawTextTtf(INFO_X, 70, fmtDec(&buf, state.level), f, WHITE);
        } else {
            drawNum(fb, INFO_X, 70, state.level);
        }
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
        fb.fillRect(BOARD_X + 2, BOARD_Y + 95, 106, 30, BLACK);
        if (font_text) |f| {
            fb.drawTextTtf(BOARD_X + 6, BOARD_Y + 100, "GAME OVER", f, 0xF800);
        }
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
        if (dy + @as(i16, racer_state.MARK_H) > 0 and dy < 240) {
            const uy: u16 = if (dy < 0) 0 else @intCast(dy);
            const visible_h: u16 = if (dy < 0) @intCast(@as(i16, racer_state.MARK_H) + dy) else racer_state.MARK_H;
            fb.fillRect(racer_state.ROAD_LEFT + racer_state.LANE_W - 1, uy, racer_state.MARK_W, visible_h, MARK_COLOR);
            fb.fillRect(racer_state.ROAD_LEFT + 2 * racer_state.LANE_W - 1, uy, racer_state.MARK_W, visible_h, MARK_COLOR);
        }
    }

    for (state.obstacles) |obs| {
        if (!obs.active) continue;
        if (obs.y + @as(i16, racer_state.OBS_H) <= 0 or obs.y >= 240) continue;
        const ox = racer_state.LANE_X[obs.lane];
        const oy: u16 = if (obs.y < 0) 0 else @intCast(obs.y);
        const visible_h: u16 = if (obs.y < 0) @intCast(@as(i16, racer_state.OBS_H) + obs.y) else racer_state.OBS_H;
        fb.fillRoundRect(ox, oy, racer_state.OBS_W, visible_h, 4, racer_state.OBS_COLORS[obs.color_idx]);
    }

    // Player car
    fb.fillRoundRect(state.player_x, racer_state.CAR_Y, racer_state.CAR_W, racer_state.CAR_H, 4, PLAYER_COLOR);
    fb.fillRect(state.player_x + 4, racer_state.CAR_Y + 4, racer_state.CAR_W - 8, 8, PLAYER_WIND);

    // HUD
    fb.fillRect(0, 0, 240, 16, BLACK);
    if (font_text) |f| {
        var buf: [10]u8 = undefined;
        fb.drawTextTtf(4, 2, fmtDec(&buf, state.score), f, WHITE);
    } else {
        drawNum(fb, 4, 4, state.score);
    }

    if (state.phase == .game_over) {
        fb.fillRect(30, 95, 180, 30, BLACK);
        if (font_text) |f| {
            fb.drawTextTtf(40, 100, "GAME OVER", f, 0xF800);
        }
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

fn fmtDec(buf: *[10]u8, val: u32) []const u8 {
    if (val == 0) { buf[9] = '0'; return buf[9..10]; }
    var v = val;
    var i: usize = 10;
    while (v > 0) : (v /= 10) { i -= 1; buf[i] = @intCast('0' + v % 10); }
    return buf[i..10];
}

fn drawNum(fb: *FB, x: u16, y: u16, value: u32) void {
    var buf: [10]u8 = undefined;
    drawDigitRow(fb, x, y, fmtDec(&buf, value));
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

