//! LVGL Switch widget
const c = @import("lvgl").c;
const Obj = @import("obj.zig");
const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_switch_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}
pub fn setChecked(self: Self, v: bool) void {
    if (v) c.lv_obj_add_state(self.obj.ptr, c.LV_STATE_CHECKED)
    else c.lv_obj_clear_state(self.obj.ptr, c.LV_STATE_CHECKED);
}
pub fn isChecked(self: Self) bool {
    return (c.lv_obj_get_state(self.obj.ptr) & c.LV_STATE_CHECKED) != 0;
}
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
