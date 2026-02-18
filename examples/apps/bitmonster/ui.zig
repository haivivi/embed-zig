//! BitMonster — UI Rendering
//!
//! Pure function: state → pixels. Uses Compositor for partial redraw.

const ui_state = @import("ui_state");
const Framebuffer = ui_state.Framebuffer;
const TtfFont = ui_state.TtfFont;
const s = @import("state.zig");
const AppState = s.AppState;

pub const FB = Framebuffer(s.SCREEN_W, s.SCREEN_H, .rgb565);

// Fonts (set by app.zig at init)
pub var font_20: ?*TtfFont = null;
pub var font_16: ?*TtfFont = null;

// Icons (set by app.zig at init, loaded from VFS)
pub const Icon = struct {
    width: u8,
    height: u8,
    data: []const u8, // 1-bit bitmap, ceil(w/8)*h bytes, MSB first
};

pub var map_icons: [9]?Icon = .{null} ** 9;
pub var back_icon: ?Icon = null;

const BLACK: u16 = 0x0000;
const WHITE: u16 = 0xFFFF;
const DARK_BG: u16 = 0x1082;
const GRID_BG: u16 = 0x2945;
const GRID_SEL: u16 = 0x4A69;
const ACCENT: u16 = 0xFD20;
const GREEN: u16 = 0x07E0;
const RED: u16 = 0xF800;
const BLUE: u16 = 0x001F;
const TEXT_DIM: u16 = 0x7BEF;

const GRID_MARGIN: u16 = 14;
const GRID_CELL: u16 = 90;
const GRID_GAP: u16 = 8;
const LABEL_H: u16 = 32;

pub fn render(fb: *FB, state: *const AppState, prev: ?*const AppState) void {
    // Page changed → full redraw
    if (prev) |p| {
        if (p.page != state.page) {
            renderFull(fb, state);
            return;
        }
    } else {
        renderFull(fb, state);
        return;
    }

    // Same page → partial
    const p = prev.?;
    switch (state.page) {
        .save_select => {
            if (state.selected_slot != p.selected_slot) renderSaveSelect(fb, state);
        },
        .main_map => renderMainMapPartial(fb, state, p),
        .place => renderPlaceFull(fb, state),
        else => {},
    }
}

fn renderFull(fb: *FB, state: *const AppState) void {
    switch (state.page) {
        .save_select => renderSaveSelect(fb, state),
        .main_map => renderMainMap(fb, state),
        .place => renderPlaceFull(fb, state),
        else => fb.fillRect(0, 0, s.SCREEN_W, s.SCREEN_H, BLACK),
    }
}

// ============================================================================
// Save Selection
// ============================================================================

fn renderSaveSelect(fb: *FB, state: *const AppState) void {
    fb.fillRect(0, 0, s.SCREEN_W, s.SCREEN_H, DARK_BG);

    // Title
    if (font_20) |f| {
        const title = "BitMonster";
        const tw = f.textWidth(title);
        fb.drawTextTtf((s.SCREEN_W -| tw) / 2, 24, title, f, ACCENT);
    }

    // 3 slots
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        const y: u16 = 80 + @as(u16, i) * 76;
        const selected = (i == state.selected_slot);
        const bg = if (selected) GRID_SEL else GRID_BG;
        fb.fillRoundRect(30, y, 260, 60, 10, bg);
        if (selected) fb.drawRect(30, y, 260, 60, ACCENT, 2);

        if (state.saves[i].active) {
            const pet = &state.saves[i].pet;
            const color: u16 = speciesColor(pet.species);
            fb.fillRoundRect(44, y + 10, 40, 40, 8, color);

            if (font_16) |f| {
                // Pet name
                const name_slice = pet.name[0..pet.name_len];
                fb.drawTextTtf(96, y + 10, name_slice, f, WHITE);

                // Level
                var lvl_buf: [12]u8 = undefined;
                const lvl_str = fmtInt(&lvl_buf, "Lv.", pet.level);
                fb.drawTextTtf(96, y + 32, lvl_str, f, TEXT_DIM);
            }

            // Health bar
            const bar_w: u16 = @as(u16, pet.health) * 120 / 100;
            fb.fillRect(200, y + 16, 120, 8, 0x2104);
            fb.fillRect(200, y + 16, bar_w, 8, GREEN);
            // Spirit bar
            const sp_w: u16 = @as(u16, pet.spirit) * 120 / 100;
            fb.fillRect(200, y + 30, 120, 8, 0x2104);
            fb.fillRect(200, y + 30, sp_w, 8, BLUE);
        } else {
            if (font_16) |f| {
                fb.drawTextTtf(110, y + 18, "New Game", f, TEXT_DIM);
            } else {
                fb.fillRect(110, y + 22, 100, 12, TEXT_DIM);
            }
        }
    }
}

fn fmtInt(buf: []u8, prefix: []const u8, val: u16) []const u8 {
    var pos: usize = 0;
    for (prefix) |c| {
        if (pos < buf.len) { buf[pos] = c; pos += 1; }
    }
    if (val == 0) {
        if (pos < buf.len) { buf[pos] = '0'; pos += 1; }
    } else {
        var tmp: [5]u8 = undefined;
        var n = val;
        var len: usize = 0;
        while (n > 0) : (n /= 10) {
            tmp[len] = @intCast('0' + n % 10);
            len += 1;
        }
        var j = len;
        while (j > 0) {
            j -= 1;
            if (pos < buf.len) { buf[pos] = tmp[j]; pos += 1; }
        }
    }
    return buf[0..pos];
}

fn speciesColor(species: s.PetSpecies) u16 {
    return switch (species) {
        .flame => 0xF800,
        .tide => 0x001F,
        .thorn => 0x07E0,
        .iron => 0xFFE0,
        .muddy => 0x8410,
    };
}

// ============================================================================
// Main Map (3x3 Grid)
// ============================================================================

const place_colors = [9]u16{
    0x4208, // home - gray
    0xFD20, // diner - orange
    0x001F, // school - blue
    0xF800, // clinic - red
    0x07E0, // pet - green (center)
    0xFFE0, // gym - yellow
    0xF81F, // arcade - magenta
    0x07FF, // lucky - cyan
    0xBDF7, // shop - light gray
};

fn renderMainMap(fb: *FB, state: *const AppState) void {
    fb.fillRect(0, 0, s.SCREEN_W, s.SCREEN_H, DARK_BG);

    // 3x3 grid
    var i: u8 = 0;
    while (i < 9) : (i += 1) {
        const col = i % 3;
        const row = i / 3;
        const x: u16 = GRID_MARGIN + @as(u16, col) * (GRID_CELL + GRID_GAP);
        const y: u16 = GRID_MARGIN + @as(u16, row) * (GRID_CELL + GRID_GAP);

        const selected = (i == state.grid_cursor);
        const bg = if (selected) GRID_SEL else GRID_BG;
        fb.fillRoundRect(x, y, GRID_CELL, GRID_CELL, 10, bg);

        // Icon placeholder (colored square in center of cell)
        fb.fillRoundRect(x + 24, y + 20, 48, 48, 8, place_colors[i]);

        // Selection border
        if (selected) fb.drawRect(x, y, GRID_CELL, GRID_CELL, ACCENT, 2);
    }

    // Bottom label bar
    renderBottomLabel(fb, state.grid_cursor);
}

fn renderMainMapPartial(fb: *FB, state: *const AppState, prev: *const AppState) void {
    if (state.grid_cursor != prev.grid_cursor) {
        // Redraw old cell (remove highlight)
        renderGridCell(fb, prev.grid_cursor, false);
        // Redraw new cell (add highlight)
        renderGridCell(fb, state.grid_cursor, true);
        // Update label
        renderBottomLabel(fb, state.grid_cursor);
    }
}

fn renderGridCell(fb: *FB, index: u8, selected: bool) void {
    const col = index % 3;
    const row = index / 3;
    const x: u16 = GRID_MARGIN + @as(u16, col) * (GRID_CELL + GRID_GAP);
    const y: u16 = GRID_MARGIN + @as(u16, row) * (GRID_CELL + GRID_GAP);

    const bg = if (selected) GRID_SEL else GRID_BG;
    fb.fillRoundRect(x, y, GRID_CELL, GRID_CELL, 12, bg);

    // Draw icon from loaded bitmap, centered in cell
    if (map_icons[index]) |icon| {
        const ix = x + (GRID_CELL - @as(u16, icon.width)) / 2;
        const iy = y + (GRID_CELL - @as(u16, icon.height)) / 2 - 2;
        drawIcon(fb, ix, iy, icon, place_colors[index]);
    } else {
        // Fallback: colored square
        fb.fillRoundRect(x + 25, y + 21, 40, 40, 8, place_colors[index]);
    }

    if (selected) {
        fb.drawRect(x, y, GRID_CELL, GRID_CELL, ACCENT, 2);
    }
}

/// Render a 1-bit icon bitmap with the given foreground color.
fn drawIcon(fb: *FB, x: u16, y: u16, icon: Icon, color: u16) void {
    const bytes_per_row = (@as(usize, icon.width) + 7) / 8;
    var row: u16 = 0;
    while (row < icon.height) : (row += 1) {
        var col: u16 = 0;
        while (col < icon.width) : (col += 1) {
            const byte_idx = @as(usize, row) * bytes_per_row + @as(usize, col) / 8;
            if (byte_idx >= icon.data.len) continue;
            const bit = @as(u8, 0x80) >> @intCast(col % 8);
            if (icon.data[byte_idx] & bit != 0) {
                fb.setPixel(x + col, y + row, color);
            }
        }
    }
}

const place_names_en = [9][]const u8{
    "Home", "Diner", "School", "Clinic", "Pet", "Gym", "Arcade", "Lucky", "Shop",
};

fn renderBottomLabel(fb: *FB, cursor: u8) void {
    const y: u16 = s.SCREEN_H - LABEL_H;
    fb.fillRect(0, y, s.SCREEN_W, LABEL_H, DARK_BG);

    if (font_20) |f| {
        const name = place_names_en[cursor];
        const tw = f.textWidth(name);
        const tx: u16 = (s.SCREEN_W -| tw) / 2;
        fb.drawTextTtf(tx, y + 4, name, f, WHITE);
    } else {
        // Fallback: colored bar
        fb.fillRoundRect(120, y + 8, 80, 16, 4, place_colors[cursor]);
    }
}

// ============================================================================
// Place pages (stub — will be expanded per place)
// ============================================================================

fn renderPlaceFull(fb: *FB, state: *const AppState) void {
    fb.fillRect(0, 0, s.SCREEN_W, s.SCREEN_H, DARK_BG);

    // Place header bar
    fb.fillRect(0, 0, s.SCREEN_W, 40, GRID_BG);
    const idx = @intFromEnum(state.current_place);
    fb.fillRoundRect(20, 8, 24, 24, 4, place_colors[idx]);

    // Back hint
    fb.fillRect(s.SCREEN_W - 60, 12, 40, 16, TEXT_DIM);

    // Placeholder content
    fb.fillRect(40, 80, s.SCREEN_W - 80, 160, GRID_BG);
}
