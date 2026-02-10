//! LVGL Label widget wrapper
//!
//! Labels display text on screen. Most common widget for embedded UIs.

const lvgl = @import("lvgl");
const c = lvgl.c;
const Obj = @import("obj.zig");

const Self = @This();

/// Underlying object
obj: Obj,

/// Create a label widget as a child of `parent`
pub fn create(parent: Obj) Self {
    const ptr = c.lv_label_create(parent.raw()) orelse unreachable;
    return .{ .obj = Obj.wrap(ptr) };
}

/// Set label text (static string, must outlive the label)
pub fn setText(self: Self, text: [*:0]const u8) void {
    c.lv_label_set_text(self.obj.ptr, text);
}

/// Set label text with a format string
pub fn setTextStatic(self: Self, text: [*:0]const u8) void {
    c.lv_label_set_text_static(self.obj.ptr, text);
}

/// Set long mode (how to handle text longer than the label width)
pub fn setLongMode(self: Self, mode: c.lv_label_long_mode_t) void {
    c.lv_label_set_long_mode(self.obj.ptr, mode);
}

// ============================================================================
// Obj delegation — common operations
// ============================================================================

/// Center in parent
pub fn center(self: Self) void {
    self.obj.center();
}

/// Align relative to parent
pub fn setAlign(self: Self, alignment: c.lv_align_t, x_ofs: i32, y_ofs: i32) void {
    self.obj.setAlign(alignment, x_ofs, y_ofs);
}

/// Set size
pub fn setSize(self: Self, w: i32, h: i32) void {
    self.obj.setSize(w, h);
}

/// Set position
pub fn setPos(self: Self, x: i32, y: i32) void {
    self.obj.setPos(x, y);
}

/// Delete this label
pub fn delete(self: Self) void {
    self.obj.delete();
}

/// Get raw LVGL object pointer
pub fn raw(self: Self) *c.lv_obj_t {
    return self.obj.raw();
}
