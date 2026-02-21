//! LVGL Button widget

const c = @import("lvgl").c;
const Obj = @import("obj.zig");

const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_button_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}

// Delegate common methods
pub fn size(self: Self, w: i32, h: i32) Self { _ = self.obj.size(w, h); return self; }
pub fn setAlign(self: Self, a: Obj.Align, x: i32, y: i32) Self { _ = self.obj.setAlign(a, x, y); return self; }
pub fn center(self: Self) Self { _ = self.obj.center(); return self; }
pub fn bgColor(self: Self, hex: u32) Self { _ = self.obj.bgColor(hex); return self; }
pub fn radius(self: Self, r: i32) Self { _ = self.obj.radius(r); return self; }
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
