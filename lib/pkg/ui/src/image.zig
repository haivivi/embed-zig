//! LVGL Image — Zig-native wrapper

const c = @import("lvgl").c;
const Obj = @import("obj.zig");

const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_image_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}

/// Set image source (lv_image_dsc_t pointer from img_helper)
pub fn src(self: Self, s: ?*const anyopaque) Self {
    c.lv_image_set_src(self.obj.ptr, s);
    return self;
}

pub fn setAlign(self: Self, a: Obj.Align, x: i32, y: i32) Self {
    _ = self.obj.setAlign(a, x, y);
    return self;
}

pub fn center(self: Self) Self {
    _ = self.obj.center();
    return self;
}

pub fn raw(self: Self) *c.lv_obj_t {
    return self.obj.ptr;
}
