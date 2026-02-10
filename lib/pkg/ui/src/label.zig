//! LVGL Label — Zig-native wrapper

const c = @import("lvgl").c;
const Obj = @import("obj.zig");

const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_label_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}

pub fn text(self: Self, t: [*:0]const u8) Self {
    c.lv_label_set_text(self.obj.ptr, t);
    return self;
}

pub fn textStatic(self: Self, t: [*:0]const u8) Self {
    c.lv_label_set_text_static(self.obj.ptr, t);
    return self;
}

// Delegate style methods to Obj
pub fn setAlign(self: Self, a: Obj.Align, x: i32, y: i32) Self {
    _ = self.obj.setAlign(a, x, y);
    return self;
}

pub fn center(self: Self) Self {
    _ = self.obj.center();
    return self;
}

pub fn color(self: Self, hex: u32) Self {
    _ = self.obj.textColor(hex);
    return self;
}

pub fn font(self: Self, f: *const c.lv_font_t) Self {
    _ = self.obj.textFont(f);
    return self;
}

pub fn hide(self: Self) Self {
    _ = self.obj.hide();
    return self;
}

pub fn show(self: Self) Self {
    _ = self.obj.show();
    return self;
}

pub fn setHidden(self: Self, hidden: bool) Self {
    _ = self.obj.setHidden(hidden);
    return self;
}

pub fn raw(self: Self) *c.lv_obj_t {
    return self.obj.ptr;
}
