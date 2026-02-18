//! Tetris — LVGL Renderer
//!
//! Same game state as framebuffer version, rendered with LVGL widgets.
//! Each board cell is an lv_obj; LVGL handles partial invalidation.

const lvgl_ui = @import("ui");
const c = @import("lvgl").c;
const game = @import("../state/tetris.zig");

pub const GameState = game.GameState;
pub const GameEvent = game.GameEvent;
pub const reduce = game.reduce;

const CELL_SIZE: i32 = 11;
const BOARD_X: i32 = 5;
const BOARD_Y: i32 = 5;
const INFO_X: i32 = BOARD_X + game.BOARD_W * CELL_SIZE + 8;

const PIECE_LV_COLORS = [7]u32{
    0x00FFFF, // I — cyan
    0x0000FF, // J — blue
    0xFF8C00, // L — orange
    0xFFFF00, // O — yellow
    0x00FF00, // S — green
    0xFF00FF, // T — purple
    0xFF0000, // Z — red
};

pub const View = struct {
    cells: [game.BOARD_H][game.BOARD_W]*c.lv_obj_t = undefined,
    score_label: *c.lv_obj_t = undefined,
    lines_label: *c.lv_obj_t = undefined,
    level_label: *c.lv_obj_t = undefined,
    gameover_label: *c.lv_obj_t = undefined,

    // Cache last rendered state to avoid redundant widget updates
    prev_colors: [game.BOARD_H][game.BOARD_W]u8 = [_][game.BOARD_W]u8{[_]u8{0xFF} ** game.BOARD_W} ** game.BOARD_H,
    prev_score: u32 = 0xFFFFFFFF,
    prev_lines: u32 = 0xFFFFFFFF,
    prev_level: u8 = 0xFF,
    prev_gameover: bool = false,

    pub fn create(screen: lvgl_ui.Obj) View {
        var self: View = .{};

        // Board background
        const board_w = game.BOARD_W * CELL_SIZE;
        const board_h = game.BOARD_H * CELL_SIZE;
        const board_bg = lvgl_ui.Obj.create(screen.raw()).?
            .pos(BOARD_X, BOARD_Y)
            .size(board_w, board_h)
            .bgColor(0x202020);

        // Create cell widgets
        for (0..game.BOARD_H) |row| {
            for (0..game.BOARD_W) |col| {
                const x: i32 = @intCast(@as(i32, @intCast(col)) * CELL_SIZE);
                const y: i32 = @intCast(@as(i32, @intCast(row)) * CELL_SIZE);
                self.cells[row][col] = lvgl_ui.Obj.create(board_bg.raw()).?
                    .pos(x, y)
                    .size(CELL_SIZE - 1, CELL_SIZE - 1)
                    .bgColor(0x202020)
                    .raw();
            }
        }

        // Score
        self.score_label = lvgl_ui.Label.create(screen).?
            .text("0")
            .setAlign(.top_left, INFO_X, 30)
            .color(0xFFFFFF)
            .raw();

        // Lines
        self.lines_label = lvgl_ui.Label.create(screen).?
            .text("0")
            .setAlign(.top_left, INFO_X, 46)
            .color(0xFFFFFF)
            .raw();

        // Level
        self.level_label = lvgl_ui.Label.create(screen).?
            .text("1")
            .setAlign(.top_left, INFO_X, 70)
            .color(0xFFFFFF)
            .raw();

        // Game over (hidden)
        self.gameover_label = lvgl_ui.Label.create(screen).?
            .text("GAME OVER")
            .center()
            .color(0xFF0000)
            .hide()
            .raw();

        return self;
    }

    pub fn sync(self: *View, state: *const GameState) void {
        // Board cells
        for (0..game.BOARD_H) |row| {
            for (0..game.BOARD_W) |col| {
                const cell_val = state.board[row][col];
                const piece_at = game.isPieceAt(state, col, row);

                const color_key: u8 = if (piece_at) |s| s + 1 else cell_val;

                if (color_key != self.prev_colors[row][col]) {
                    self.prev_colors[row][col] = color_key;
                    const obj = lvgl_ui.Obj{ .ptr = self.cells[row][col] };
                    if (color_key > 0) {
                        _ = obj.bgColor(PIECE_LV_COLORS[color_key - 1]);
                    } else {
                        _ = obj.bgColor(0x202020);
                    }
                }
            }
        }

        // Score
        if (state.score != self.prev_score) {
            self.prev_score = state.score;
            var buf: [12]u8 = undefined;
            const s = fmtU32(&buf, state.score);
            c.lv_label_set_text(self.score_label, @ptrCast(s.ptr));
        }

        // Lines
        if (state.lines != self.prev_lines) {
            self.prev_lines = state.lines;
            var buf: [12]u8 = undefined;
            const s = fmtU32(&buf, state.lines);
            c.lv_label_set_text(self.lines_label, @ptrCast(s.ptr));
        }

        // Level
        if (state.level != self.prev_level) {
            self.prev_level = state.level;
            var buf: [12]u8 = undefined;
            const s = fmtU32(&buf, state.level);
            c.lv_label_set_text(self.level_label, @ptrCast(s.ptr));
        }

        // Game over
        if (state.phase == .game_over and !self.prev_gameover) {
            self.prev_gameover = true;
            const obj = lvgl_ui.Obj{ .ptr = self.gameover_label };
            _ = obj.show();
        } else if (state.phase != .game_over and self.prev_gameover) {
            self.prev_gameover = false;
            const obj = lvgl_ui.Obj{ .ptr = self.gameover_label };
            _ = obj.hide();
        }
    }
};

fn fmtU32(buf: *[12]u8, val: u32) [:0]const u8 {
    if (val == 0) {
        buf[0] = '0';
        buf[1] = 0;
        return buf[0..1 :0];
    }
    var v = val;
    var i: usize = 11;
    buf[11] = 0;
    while (v > 0 and i > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + v % 10);
    }
    // Copy to start
    const len = 11 - i;
    var j: usize = 0;
    while (j < len) : (j += 1) buf[j] = buf[i + j];
    buf[len] = 0;
    return buf[0..len :0];
}
