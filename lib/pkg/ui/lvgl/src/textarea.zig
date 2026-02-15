//! LVGL Textarea widget
const c = @import("lvgl").c;
const Obj = @import("obj.zig");
const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_textarea_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}
pub fn setText(self: Self, t: [*:0]const u8) Self { c.lv_textarea_set_text(self.obj.ptr, t); return self; }
pub fn addText(self: Self, t: [*:0]const u8) Self { c.lv_textarea_add_text(self.obj.ptr, t); return self; }
pub fn addChar(self: Self, ch: u32) Self { c.lv_textarea_add_char(self.obj.ptr, ch); return self; }
pub fn setPlaceholder(self: Self, t: [*:0]const u8) Self { c.lv_textarea_set_placeholder_text(self.obj.ptr, t); return self; }
pub fn setPassword(self: Self, v: bool) Self { c.lv_textarea_set_password_mode(self.obj.ptr, v); return self; }
pub fn setOneLine(self: Self, v: bool) Self { c.lv_textarea_set_one_line(self.obj.ptr, v); return self; }
pub fn setMaxLength(self: Self, len: u32) Self { c.lv_textarea_set_max_length(self.obj.ptr, len); return self; }
pub fn size(self: Self, w: i32, h: i32) Self { _ = self.obj.size(w, h); return self; }
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
