//! LVGL Dropdown widget
const c = @import("lvgl").c;
const Obj = @import("obj.zig");
const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_dropdown_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}
pub fn setOptions(self: Self, opts: [*:0]const u8) Self { c.lv_dropdown_set_options(self.obj.ptr, opts); return self; }
pub fn setSelected(self: Self, idx: u32) Self { c.lv_dropdown_set_selected(self.obj.ptr, @intCast(idx)); return self; }
pub fn getSelected(self: Self) u32 { return c.lv_dropdown_get_selected(self.obj.ptr); }
pub fn size(self: Self, w: i32, h: i32) Self { _ = self.obj.size(w, h); return self; }
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
