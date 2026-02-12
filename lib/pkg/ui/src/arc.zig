//! LVGL Arc widget
const c = @import("lvgl").c;
const Obj = @import("obj.zig");
const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_arc_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}
pub fn setRange(self: Self, min: u16, max: u16) Self { c.lv_arc_set_range(self.obj.ptr, min, max); return self; }
pub fn setValue(self: Self, val: u16) Self { c.lv_arc_set_value(self.obj.ptr, val); return self; }
pub fn setBgAngles(self: Self, start: u32, end_: u32) Self { c.lv_arc_set_bg_angles(self.obj.ptr, @intCast(start), @intCast(end_)); return self; }
pub fn setRotation(self: Self, r: u32) Self { c.lv_arc_set_rotation(self.obj.ptr, @intCast(r)); return self; }
pub fn size(self: Self, w: i32, h: i32) Self { _ = self.obj.size(w, h); return self; }
pub fn center(self: Self) Self { _ = self.obj.center(); return self; }
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
