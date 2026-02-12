//! LVGL Checkbox widget
const c = @import("lvgl").c;
const Obj = @import("obj.zig");
const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_checkbox_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}
pub fn text(self: Self, t: [*:0]const u8) Self { c.lv_checkbox_set_text(self.obj.ptr, t); return self; }
pub fn setChecked(self: Self, v: bool) void {
    if (v) c.lv_obj_add_state(self.obj.ptr, c.LV_STATE_CHECKED)
    else c.lv_obj_clear_state(self.obj.ptr, c.LV_STATE_CHECKED);
}
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
