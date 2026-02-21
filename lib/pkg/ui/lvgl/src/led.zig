//! LVGL LED widget
const c = @import("lvgl").c;
const Obj = @import("obj.zig");
const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_led_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}
pub fn setColor(self: Self, hex: u32) Self { c.lv_led_set_color(self.obj.ptr, c.lv_color_hex(hex)); return self; }
pub fn setBrightness(self: Self, b: u8) Self { c.lv_led_set_brightness(self.obj.ptr, b); return self; }
pub fn on(self: Self) Self { c.lv_led_on(self.obj.ptr); return self; }
pub fn off(self: Self) Self { c.lv_led_off(self.obj.ptr); return self; }
pub fn toggle(self: Self) Self { c.lv_led_toggle(self.obj.ptr); return self; }
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
