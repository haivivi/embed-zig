//! LVGL Bar / Progress bar widget

const c = @import("lvgl").c;
const Obj = @import("obj.zig");

const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_bar_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}

pub fn range(self: Self, min: i32, max: i32) Self {
    c.lv_bar_set_range(self.obj.ptr, min, max);
    return self;
}

pub fn value(self: Self, val: i32, anim: bool) Self {
    c.lv_bar_set_value(self.obj.ptr, val, if (anim) c.LV_ANIM_ON else c.LV_ANIM_OFF);
    return self;
}

pub fn startValue(self: Self, val: i32, anim: bool) Self {
    c.lv_bar_set_start_value(self.obj.ptr, val, if (anim) c.LV_ANIM_ON else c.LV_ANIM_OFF);
    return self;
}

// Delegate common
pub fn size(self: Self, w: i32, h: i32) Self { _ = self.obj.size(w, h); return self; }
pub fn setAlign(self: Self, a: Obj.Align, x: i32, y: i32) Self { _ = self.obj.setAlign(a, x, y); return self; }
pub fn center(self: Self) Self { _ = self.obj.center(); return self; }
pub fn bgColor(self: Self, hex: u32) Self { _ = self.obj.bgColor(hex); return self; }
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
