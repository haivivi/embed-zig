//! BitMonster — UI Tests

const std = @import("std");
const t = std.testing;

const icon_mod = @import("icon.zig");
const grid = @import("grid.zig");
const save_select = @import("save_select.zig");
const Icon = icon_mod.Icon;
const SlotView = save_select.SlotView;
const SaveSelectState = save_select.SaveSelectState;

// ============================================================================
// Mock framebuffer for testing
// ============================================================================

const MockFB = struct {
    fill_count: u32 = 0,
    set_pixel_count: u32 = 0,
    last_fill_x: u16 = 0,
    last_fill_y: u16 = 0,
    last_fill_w: u16 = 0,
    last_fill_h: u16 = 0,
    last_fill_color: u16 = 0,
    draw_rect_count: u32 = 0,

    pub fn fillRect(self: *MockFB, x: u16, y: u16, w: u16, h: u16, color: u16) void {
        self.fill_count += 1;
        self.last_fill_x = x;
        self.last_fill_y = y;
        self.last_fill_w = w;
        self.last_fill_h = h;
        self.last_fill_color = color;
    }

    pub fn fillRoundRect(self: *MockFB, x: u16, y: u16, w: u16, h: u16, _: u8, color: u16) void {
        self.fillRect(x, y, w, h, color);
    }

    pub fn drawRect(self: *MockFB, _: u16, _: u16, _: u16, _: u16, _: u16, _: u8) void {
        self.draw_rect_count += 1;
    }

    pub fn setPixel(self: *MockFB, _: u16, _: u16, _: u16) void {
        self.set_pixel_count += 1;
    }
};

// ============================================================================
// Icon tests
// ============================================================================

test "icon: fromData valid 8x8" {
    // 8x8 = 1 byte per row × 8 rows = 8 bytes + 2 header = 10 total
    const data = [_]u8{ 8, 8, 0xFF, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0xFF };
    const icon = Icon.fromData(&data);
    try t.expect(icon != null);
    try t.expectEqual(@as(u8, 8), icon.?.width);
    try t.expectEqual(@as(u8, 8), icon.?.height);
    try t.expectEqual(@as(usize, 8), icon.?.data.len);
}

test "icon: fromData valid 32x32" {
    var data: [2 + 128]u8 = undefined;
    data[0] = 32;
    data[1] = 32;
    @memset(data[2..], 0xAA);
    const icon = Icon.fromData(&data);
    try t.expect(icon != null);
    try t.expectEqual(@as(u8, 32), icon.?.width);
    try t.expectEqual(@as(usize, 128), icon.?.data.len);
}

test "icon: fromData valid 24x24" {
    var data: [2 + 72]u8 = undefined; // 24/8 * 24 = 72
    data[0] = 24;
    data[1] = 24;
    @memset(data[2..], 0);
    const icon = Icon.fromData(&data);
    try t.expect(icon != null);
    try t.expectEqual(@as(u8, 24), icon.?.width);
}

test "icon: fromData too short" {
    const data = [_]u8{32};
    try t.expect(Icon.fromData(&data) == null);
}

test "icon: fromData zero size" {
    const data = [_]u8{ 0, 0 };
    try t.expect(Icon.fromData(&data) == null);
}

test "icon: fromData truncated bitmap" {
    const data = [_]u8{ 32, 32, 0, 0, 0 }; // needs 128 bytes, has 3
    try t.expect(Icon.fromData(&data) == null);
}

test "icon: getPixel" {
    // 8x8 icon, first row all 1s, rest all 0s
    const data = [_]u8{ 8, 8, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const icon = Icon.fromData(&data).?;
    try t.expect(icon.getPixel(0, 0));
    try t.expect(icon.getPixel(7, 0));
    try t.expect(!icon.getPixel(0, 1));
    try t.expect(!icon.getPixel(7, 7));
}

test "icon: getPixel out of bounds" {
    const data = [_]u8{ 8, 8, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const icon = Icon.fromData(&data).?;
    try t.expect(!icon.getPixel(8, 0)); // out of bounds
    try t.expect(!icon.getPixel(0, 8));
    try t.expect(!icon.getPixel(255, 255));
}

test "icon: getPixel checkerboard" {
    // 8x2 icon: row 0 = 0xAA (10101010), row 1 = 0x55 (01010101)
    const data = [_]u8{ 8, 2, 0xAA, 0x55 };
    const icon = Icon.fromData(&data).?;
    try t.expect(icon.getPixel(0, 0)); // MSB = 1
    try t.expect(!icon.getPixel(1, 0));
    try t.expect(icon.getPixel(2, 0));
    try t.expect(!icon.getPixel(0, 1));
    try t.expect(icon.getPixel(1, 1));
}

test "icon: pixelCount" {
    const data = [_]u8{ 8, 1, 0xFF }; // 8 pixels set
    const icon = Icon.fromData(&data).?;
    try t.expectEqual(@as(u32, 8), icon.pixelCount());
}

test "icon: pixelCount empty" {
    const data = [_]u8{ 8, 1, 0x00 };
    const icon = Icon.fromData(&data).?;
    try t.expectEqual(@as(u32, 0), icon.pixelCount());
}

test "icon: bytesPerRow" {
    var data8: [10]u8 = undefined;
    data8[0] = 8;
    data8[1] = 8;
    try t.expectEqual(@as(usize, 1), Icon.fromData(&data8).?.bytesPerRow());

    var data32: [130]u8 = undefined;
    data32[0] = 32;
    data32[1] = 32;
    try t.expectEqual(@as(usize, 4), Icon.fromData(&data32).?.bytesPerRow());

    var data24: [74]u8 = undefined;
    data24[0] = 24;
    data24[1] = 24;
    try t.expectEqual(@as(usize, 3), Icon.fromData(&data24).?.bytesPerRow());
}

test "icon: draw calls setPixel" {
    // 4x2 icon, first row = 0xF0 (1111 0000), second row = 0x0F (0000 1111)
    const data = [_]u8{ 4, 2, 0xF0, 0xF0 };
    const icon = Icon.fromData(&data).?;

    var fb = MockFB{};
    icon.draw(&fb, 10, 20, 0xFFFF);
    try t.expectEqual(@as(u32, 8), fb.set_pixel_count); // 4 + 4 pixels
}

test "icon: draw zero icon no crash" {
    const data = [_]u8{ 8, 8, 0, 0, 0, 0, 0, 0, 0, 0 };
    const icon = Icon.fromData(&data).?;
    var fb = MockFB{};
    icon.draw(&fb, 0, 0, 0xFFFF);
    try t.expectEqual(@as(u32, 0), fb.set_pixel_count);
}

// ============================================================================
// Icon: synthetic data tests (verifying .icon format parsing)
// ============================================================================

test "icon: 32x32 synthetic full" {
    var data: [130]u8 = undefined;
    data[0] = 32;
    data[1] = 32;
    @memset(data[2..], 0xFF); // all pixels set
    const icon = Icon.fromData(&data).?;
    try t.expectEqual(@as(u32, 1024), icon.pixelCount()); // 32*32
}

test "icon: 24x24 synthetic half" {
    var data: [74]u8 = undefined;
    data[0] = 24;
    data[1] = 24;
    @memset(data[2..], 0xAA); // alternating bits
    const icon = Icon.fromData(&data).?;
    try t.expect(icon.pixelCount() > 0);
    try t.expect(icon.pixelCount() < 576); // less than 24*24
}

// ============================================================================
// Grid tests
// ============================================================================

test "grid: cellPos corners" {
    const cfg = grid.default_config;
    const tl = grid.cellPos(0, cfg); // top-left
    try t.expectEqual(@as(u16, 14), tl.x);
    try t.expectEqual(@as(u16, 14), tl.y);

    const br = grid.cellPos(8, cfg); // bottom-right
    try t.expectEqual(@as(u16, 14 + 2 * 98), br.x); // margin + 2*(cell+gap)
    try t.expectEqual(@as(u16, 14 + 2 * 98), br.y);
}

test "grid: cellPos center" {
    const pos = grid.cellPos(4, grid.default_config);
    try t.expectEqual(@as(u16, 14 + 98), pos.x);
    try t.expectEqual(@as(u16, 14 + 98), pos.y);
}

test "grid: cellRect size" {
    const rect = grid.cellRect(0, grid.default_config);
    try t.expectEqual(@as(u16, 90), rect.w);
    try t.expectEqual(@as(u16, 90), rect.h);
}

test "grid: labelRect at bottom" {
    const lr = grid.labelRect(grid.default_config);
    try t.expectEqual(@as(u16, 320 - 32), lr.y);
    try t.expectEqual(@as(u16, 320), lr.w);
    try t.expectEqual(@as(u16, 32), lr.h);
}

test "grid: iconOffset centers icon in cell" {
    const pos = grid.iconOffset(0, 32, 32, grid.default_config);
    const cell_pos = grid.cellPos(0, grid.default_config);
    // Icon should be centered: cell_x + (90-32)/2 = cell_x + 29
    try t.expectEqual(cell_pos.x + 29, pos.x);
}

test "grid: renderCell calls fb methods" {
    var fb = MockFB{};
    grid.renderCell(&fb, 0, false, null, 0xFFFF, grid.default_config);
    try t.expect(fb.fill_count > 0); // fillRoundRect was called
    try t.expectEqual(@as(u32, 0), fb.draw_rect_count); // no border when not selected
}

test "grid: renderCell selected draws border" {
    var fb = MockFB{};
    grid.renderCell(&fb, 0, true, null, 0xFFFF, grid.default_config);
    try t.expectEqual(@as(u32, 1), fb.draw_rect_count);
}

test "grid: renderCell with icon draws pixels" {
    const icon_data = [_]u8{ 8, 8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const icon = Icon.fromData(&icon_data).?;

    var fb = MockFB{};
    grid.renderCell(&fb, 0, false, icon, 0xFFFF, grid.default_config);
    try t.expect(fb.set_pixel_count > 0); // icon pixels drawn
}

test "grid: renderGrid draws all 9 cells" {
    var fb = MockFB{};
    const icons = [_]?Icon{null} ** 9;
    const colors = [_]u16{0xFFFF} ** 9;
    grid.renderGrid(&fb, 4, icons, colors, grid.default_config);
    try t.expectEqual(@as(u32, 9), fb.fill_count); // 9 fillRoundRect calls
    try t.expectEqual(@as(u32, 1), fb.draw_rect_count); // 1 selected border
}

// ============================================================================
// Save select tests
// ============================================================================

test "save_select: slotRect positions" {
    const cfg = save_select.default_config;
    const r0 = save_select.slotRect(0, cfg);
    const r1 = save_select.slotRect(1, cfg);
    const r2 = save_select.slotRect(2, cfg);

    try t.expectEqual(@as(u16, 80), r0.y);
    try t.expect(r1.y > r0.y);
    try t.expect(r2.y > r1.y);
    try t.expectEqual(r0.w, r1.w); // all same width
}

test "save_select: speciesColor distinct" {
    const colors = [_]u16{
        save_select.speciesColor(.flame),
        save_select.speciesColor(.tide),
        save_select.speciesColor(.thorn),
        save_select.speciesColor(.iron),
        save_select.speciesColor(.muddy),
    };
    // All should be different
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var j = i + 1;
        while (j < 5) : (j += 1) {
            try t.expect(colors[i] != colors[j]);
        }
    }
}

test "save_select: render empty slots" {
    var fb = MockFB{};
    const state = SaveSelectState{};
    save_select.render(&fb, &state, save_select.default_config);
    try t.expect(fb.fill_count >= 4);
    try t.expectEqual(@as(u32, 1), fb.draw_rect_count);
}

test "save_select: render with active pet shows bars" {
    var fb = MockFB{};
    var state = SaveSelectState{};
    state.slots[0] = .{ .active = true, .pet = .{ .species = .flame, .health = 80, .spirit = 60 } };
    save_select.render(&fb, &state, save_select.default_config);
    try t.expect(fb.fill_count >= 8);
}

test "save_select: renderSlot selected vs unselected" {
    var fb_sel = MockFB{};
    var fb_unsel = MockFB{};
    const slot = SlotView{};

    save_select.renderSlot(&fb_sel, 0, &slot, true, save_select.default_config);
    save_select.renderSlot(&fb_unsel, 0, &slot, false, save_select.default_config);

    try t.expectEqual(@as(u32, 1), fb_sel.draw_rect_count);
    try t.expectEqual(@as(u32, 0), fb_unsel.draw_rect_count);
}
