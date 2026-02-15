//! LVGL Canvas widget — pixel-level drawing

const c = @import("lvgl").c;
const Obj = @import("obj.zig");

const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_canvas_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}

/// Set the draw buffer (must persist for canvas lifetime)
pub fn setBuffer(self: Self, buf: [*]u8, w: u32, h: u32) Self {
    c.lv_canvas_set_buffer(self.obj.ptr, buf, @intCast(w), @intCast(h), c.LV_COLOR_FORMAT_RGB565);
    return self;
}

/// Fill entire canvas with a color
pub fn fillBg(self: Self, hex: u32) Self {
    c.lv_canvas_fill_bg(self.obj.ptr, c.lv_color_hex(hex), c.LV_OPA_COVER);
    return self;
}

/// Set a single pixel
pub fn setPixel(self: Self, x: i32, y: i32, hex: u32) void {
    c.lv_canvas_set_px(self.obj.ptr, x, y, c.lv_color_hex(hex), c.LV_OPA_COVER);
}

/// Invalidate to trigger redraw
pub fn invalidate(self: Self) void {
    c.lv_obj_invalidate(self.obj.ptr);
}

pub fn size(self: Self, w: i32, h: i32) Self { _ = self.obj.size(w, h); return self; }
pub fn setAlign(self: Self, a: Obj.Align, x: i32, y: i32) Self { _ = self.obj.setAlign(a, x, y); return self; }
pub fn center(self: Self) Self { _ = self.obj.center(); return self; }
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
