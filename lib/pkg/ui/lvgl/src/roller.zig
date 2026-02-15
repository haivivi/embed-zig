//! LVGL Roller widget
const c = @import("lvgl").c;
const Obj = @import("obj.zig");
const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_roller_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}
pub fn setOptions(self: Self, opts: [*:0]const u8, infinite: bool) Self {
    c.lv_roller_set_options(self.obj.ptr, opts, if (infinite) c.LV_ROLLER_MODE_INFINITE else c.LV_ROLLER_MODE_NORMAL);
    return self;
}
pub fn setSelected(self: Self, idx: u32, anim: bool) Self {
    c.lv_roller_set_selected(self.obj.ptr, @intCast(idx), if (anim) c.LV_ANIM_ON else c.LV_ANIM_OFF);
    return self;
}
pub fn getSelected(self: Self) u32 { return c.lv_roller_get_selected(self.obj.ptr); }
pub fn setVisibleRows(self: Self, rows: u32) Self { c.lv_roller_set_visible_row_count(self.obj.ptr, rows); return self; }
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
