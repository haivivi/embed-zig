//! LVGL Line widget
const c = @import("lvgl").c;
const Obj = @import("obj.zig");
const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_line_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}
pub fn setPoints(self: Self, points: [*]const c.lv_point_precise_t, count: u32) Self {
    c.lv_line_set_points(self.obj.ptr, points, count);
    return self;
}
pub fn setYInvert(self: Self, v: bool) Self { c.lv_line_set_y_invert(self.obj.ptr, v); return self; }
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
