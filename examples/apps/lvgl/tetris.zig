//! Tetris — Classic falling blocks
//!
//! 10x20 grid, 11px cells on 240x240 screen.
//! left/right = move, vol_up = rotate, vol_down = fast drop, confirm = hard drop

const c = @import("lvgl").c;
const ButtonId = @import("platform.zig").ButtonId;

const COLS = 10;
const ROWS = 20;
const CELL = 11;
const OX = 15; // offset x to center
const OY = 10;
const W = 240;
const H = 240;

var screen: ?*c.lv_obj_t = null;
var canvas: ?*c.lv_obj_t = null;
var lbl: ?*c.lv_obj_t = null;
var buf: [W * H * 2]u8 align(4) = undefined;

// Board: 0 = empty, 1-7 = piece color
var board: [ROWS][COLS]u8 = [_][COLS]u8{[_]u8{0} ** COLS} ** ROWS;
var cur_piece: u8 = 0;
var cur_rot: u8 = 0;
var cur_x: i8 = 3;
var cur_y: i8 = 0;
var score: u32 = 0;
var lines: u32 = 0;
var alive: bool = true;
var tick: u32 = 0;
var drop_speed: u32 = 30;
var rng_state: u32 = 77;

fn rng() u32 {
    rng_state = rng_state *% 1103515245 +% 12345;
    return (rng_state >> 16) & 0x7FFF;
}

// Piece definitions: each piece has 4 rotations, each rotation is 4 (x,y) cells
// Encoded as [piece][rotation][cell] = {dx, dy}
const pieces = [7][4][4][2]i8{
    // I
    .{ .{ .{0,1}, .{1,1}, .{2,1}, .{3,1} }, .{ .{2,0}, .{2,1}, .{2,2}, .{2,3} }, .{ .{0,2}, .{1,2}, .{2,2}, .{3,2} }, .{ .{1,0}, .{1,1}, .{1,2}, .{1,3} } },
    // O
    .{ .{ .{1,0}, .{2,0}, .{1,1}, .{2,1} }, .{ .{1,0}, .{2,0}, .{1,1}, .{2,1} }, .{ .{1,0}, .{2,0}, .{1,1}, .{2,1} }, .{ .{1,0}, .{2,0}, .{1,1}, .{2,1} } },
    // T
    .{ .{ .{1,0}, .{0,1}, .{1,1}, .{2,1} }, .{ .{1,0}, .{1,1}, .{2,1}, .{1,2} }, .{ .{0,1}, .{1,1}, .{2,1}, .{1,2} }, .{ .{1,0}, .{0,1}, .{1,1}, .{1,2} } },
    // S
    .{ .{ .{1,0}, .{2,0}, .{0,1}, .{1,1} }, .{ .{1,0}, .{1,1}, .{2,1}, .{2,2} }, .{ .{1,1}, .{2,1}, .{0,2}, .{1,2} }, .{ .{0,0}, .{0,1}, .{1,1}, .{1,2} } },
    // Z
    .{ .{ .{0,0}, .{1,0}, .{1,1}, .{2,1} }, .{ .{2,0}, .{1,1}, .{2,1}, .{1,2} }, .{ .{0,1}, .{1,1}, .{1,2}, .{2,2} }, .{ .{1,0}, .{0,1}, .{1,1}, .{0,2} } },
    // L
    .{ .{ .{2,0}, .{0,1}, .{1,1}, .{2,1} }, .{ .{1,0}, .{1,1}, .{1,2}, .{2,2} }, .{ .{0,1}, .{1,1}, .{2,1}, .{0,2} }, .{ .{0,0}, .{1,0}, .{1,1}, .{1,2} } },
    // J
    .{ .{ .{0,0}, .{0,1}, .{1,1}, .{2,1} }, .{ .{1,0}, .{2,0}, .{1,1}, .{1,2} }, .{ .{0,1}, .{1,1}, .{2,1}, .{2,2} }, .{ .{1,0}, .{1,1}, .{0,2}, .{1,2} } },
};

const piece_colors = [_]u32{ 0x06b6d4, 0xfbbf24, 0xc084fc, 0x4ade80, 0xf87171, 0xfb923c, 0x6c8cff };

pub fn init() void {
    screen = c.lv_obj_create(null);
    c.lv_obj_set_style_bg_color(screen.?, c.lv_color_hex(0x0a0a1e), 0);
    canvas = c.lv_canvas_create(screen.?);
    c.lv_canvas_set_buffer(canvas.?, &buf, W, H, c.LV_COLOR_FORMAT_RGB565);
    lbl = c.lv_label_create(screen.?);
    c.lv_obj_set_style_text_color(lbl, c.lv_color_hex(0x888899), 0);
    c.lv_obj_align(lbl, c.LV_ALIGN_BOTTOM_LEFT, 4, -4);
    reset();
    c.lv_screen_load(screen.?);
}

pub fn deinit() void {
    if (screen) |s| { c.lv_obj_delete(s); screen = null; canvas = null; }
}

fn reset() void {
    for (&board) |*row| for (row) |*cell| { cell.* = 0; };
    score = 0;
    lines = 0;
    alive = true;
    drop_speed = 30;
    spawnPiece();
}

fn spawnPiece() void {
    cur_piece = @intCast(rng() % 7);
    cur_rot = 0;
    cur_x = 3;
    cur_y = 0;
    if (!fits(cur_x, cur_y, cur_piece, cur_rot)) alive = false;
}

fn fits(x: i8, y: i8, piece: u8, rot: u8) bool {
    for (pieces[piece][rot]) |cell| {
        const bx = x + cell[0];
        const by = y + cell[1];
        if (bx < 0 or bx >= COLS or by < 0 or by >= ROWS) return false;
        if (board[@intCast(by)][@intCast(bx)] != 0) return false;
    }
    return true;
}

fn lock() void {
    for (pieces[cur_piece][cur_rot]) |cell| {
        const bx: usize = @intCast(cur_x + cell[0]);
        const by: usize = @intCast(cur_y + cell[1]);
        if (by < ROWS and bx < COLS) board[by][bx] = cur_piece + 1;
    }
    clearLines();
    spawnPiece();
}

fn clearLines() void {
    var dst: usize = ROWS;
    while (dst > 0) {
        dst -= 1;
        var full = true;
        for (board[dst]) |cell| if (cell == 0) { full = false; break; };
        if (full) {
            // Shift everything above down
            var y: usize = dst;
            while (y > 0) : (y -= 1) board[y] = board[y - 1];
            board[0] = [_]u8{0} ** COLS;
            lines += 1;
            score += 100;
            dst += 1; // recheck same row
            if (drop_speed > 8) drop_speed -= 2;
        }
    }
}

pub fn step(btn: ?ButtonId) void {
    tick += 1;
    if (!alive) {
        if (btn != null and btn.? == .confirm) reset();
        draw();
        return;
    }
    if (btn) |b| switch (b) {
        .left => if (fits(cur_x - 1, cur_y, cur_piece, cur_rot)) { cur_x -= 1; },
        .right => if (fits(cur_x + 1, cur_y, cur_piece, cur_rot)) { cur_x += 1; },
        .vol_up => {
            const nr = (cur_rot + 1) % 4;
            if (fits(cur_x, cur_y, cur_piece, nr)) cur_rot = nr;
        },
        .vol_down => {
            while (fits(cur_x, cur_y + 1, cur_piece, cur_rot)) cur_y += 1;
        },
        .confirm => {
            while (fits(cur_x, cur_y + 1, cur_piece, cur_rot)) cur_y += 1;
            lock();
        },
        else => {},
    };

    // Auto drop
    if (tick % drop_speed == 0) {
        if (fits(cur_x, cur_y + 1, cur_piece, cur_rot)) {
            cur_y += 1;
        } else {
            lock();
        }
    }
    draw();
}

fn draw() void {
    if (canvas == null) return;
    c.lv_canvas_fill_bg(canvas.?, c.lv_color_hex(0x0a0a1e), c.LV_OPA_COVER);

    // Draw board grid
    for (0..ROWS) |y| {
        for (0..COLS) |x| {
            const cx: i32 = OX + @as(i32, @intCast(x)) * CELL;
            const cy: i32 = OY + @as(i32, @intCast(y)) * CELL;
            if (board[y][x] > 0) {
                fillRect(cx, cy, CELL - 1, CELL - 1, piece_colors[board[y][x] - 1]);
            } else {
                fillRect(cx, cy, CELL - 1, CELL - 1, 0x111122);
            }
        }
    }

    // Draw current piece
    if (alive) {
        for (pieces[cur_piece][cur_rot]) |cell| {
            const cx: i32 = OX + (@as(i32, cur_x) + cell[0]) * CELL;
            const cy: i32 = OY + (@as(i32, cur_y) + cell[1]) * CELL;
            fillRect(cx, cy, CELL - 1, CELL - 1, piece_colors[cur_piece]);
        }
    }

    // Score area (right side)
    const sx: i32 = OX + COLS * CELL + 10;
    fillRect(sx, 20, 80, 16, 0x111122);
    fillRect(sx, 50, 80, 16, 0x111122);

    c.lv_obj_invalidate(canvas.?);
    if (lbl) |l| {
        if (!alive)
            c.lv_label_set_text(l, "Game Over! OK=retry")
        else
            c.lv_label_set_text(l, "< > Rot=Up Drop=Down");
    }
}

fn fillRect(x: i32, y: i32, w: i32, h: i32, color: u32) void {
    const col = c.lv_color_hex(color);
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            const px2 = x + dx;
            const py2 = y + dy;
            if (px2 >= 0 and px2 < W and py2 >= 0 and py2 < H)
                c.lv_canvas_set_px(canvas.?, px2, py2, col, c.LV_OPA_COVER);
        }
    }
}
