//! BitMonster — UI Rendering
//!
//! Pure function: state → pixels. Uses Compositor for partial redraw.

const ui_state = @import("ui_state");
const Framebuffer = ui_state.Framebuffer;
const s = @import("state.zig");
const AppState = s.AppState;

pub const FB = Framebuffer(s.SCREEN_W, s.SCREEN_H, .rgb565);

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

const GRID_MARGIN: u16 = 10;
const GRID_CELL: u16 = 96;
const GRID_GAP: u16 = 6;
const LABEL_H: u16 = 28;

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
    fb.fillRect(80, 20, 160, 24, ACCENT);

    // 3 slots
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        const y: u16 = 80 + @as(u16, i) * 70;
        const selected = (i == state.selected_slot);
        const bg = if (selected) GRID_SEL else GRID_BG;
        fb.fillRoundRect(30, y, 260, 56, 8, bg);
        if (selected) fb.drawRect(30, y, 260, 56, ACCENT, 2);

        if (state.saves[i].active) {
            // Show pet species color indicator
            const color: u16 = speciesColor(state.saves[i].pet.species);
            fb.fillRoundRect(42, y + 12, 32, 32, 6, color);
            // Level indicator
            fb.fillRect(86, y + 18, 60, 8, WHITE);
            // Health bar
            const hw: u16 = @as(u16, state.saves[i].pet.health) * 100 / 100;
            fb.fillRect(86, y + 32, 100, 6, 0x2104);
            fb.fillRect(86, y + 32, hw, 6, GREEN);
        } else {
            fb.fillRect(110, y + 22, 100, 12, TEXT_DIM);
        }
    }
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
    fb.fillRoundRect(x, y, GRID_CELL, GRID_CELL, 10, bg);
    fb.fillRoundRect(x + 24, y + 20, 48, 48, 8, place_colors[index]);

    if (selected) {
        fb.drawRect(x, y, GRID_CELL, GRID_CELL, ACCENT, 2);
    }
}

fn renderBottomLabel(fb: *FB, cursor: u8) void {
    const y: u16 = s.SCREEN_H - LABEL_H;
    fb.fillRect(0, y, s.SCREEN_W, LABEL_H, DARK_BG);

    // Place name as colored bar (placeholder until TTF text)
    const label_w: u16 = 80;
    const lx: u16 = (s.SCREEN_W - label_w) / 2;
    fb.fillRoundRect(lx, y + 6, label_w, 16, 4, place_colors[cursor]);
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
