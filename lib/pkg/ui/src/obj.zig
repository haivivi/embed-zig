//! LVGL Object wrapper — base for all widgets
//!
//! Every LVGL widget is an lv_obj_t. This provides the common interface.

const lvgl = @import("lvgl");
const c = lvgl.c;

const Self = @This();

/// Raw LVGL object pointer
ptr: *c.lv_obj_t,

/// Wrap a raw LVGL object pointer
pub fn wrap(obj: ?*c.lv_obj_t) Self {
    return .{ .ptr = obj.? };
}

/// Get the raw pointer (for passing to C APIs)
pub fn raw(self: Self) *c.lv_obj_t {
    return self.ptr;
}

// ============================================================================
// Position & Size
// ============================================================================

/// Set size in pixels
pub fn setSize(self: Self, w: i32, h: i32) void {
    c.lv_obj_set_size(self.ptr, w, h);
}

/// Set width in pixels
pub fn setWidth(self: Self, w: i32) void {
    c.lv_obj_set_width(self.ptr, w);
}

/// Set height in pixels
pub fn setHeight(self: Self, h: i32) void {
    c.lv_obj_set_height(self.ptr, h);
}

/// Set position
pub fn setPos(self: Self, x: i32, y: i32) void {
    c.lv_obj_set_pos(self.ptr, x, y);
}

// ============================================================================
// Alignment
// ============================================================================

/// Align relative to parent
pub fn setAlign(self: Self, alignment: c.lv_align_t, x_ofs: i32, y_ofs: i32) void {
    c.lv_obj_align(self.ptr, alignment, x_ofs, y_ofs);
}

/// Center in parent
pub fn center(self: Self) void {
    c.lv_obj_center(self.ptr);
}

// ============================================================================
// Lifecycle
// ============================================================================

/// Delete this object and all its children
pub fn delete(self: Self) void {
    c.lv_obj_delete(self.ptr);
}

/// Create a plain object (container) as a child
pub fn createChild(self: Self) Self {
    return wrap(c.lv_obj_create(self.ptr));
}
