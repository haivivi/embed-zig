//! LVGL Event API
//!
//! ```zig
//! ui.event.on(my_btn.obj, .clicked, myCallback, null);
//! ```

const c = @import("lvgl").c;
const Obj = @import("obj.zig");

pub const Code = enum(c_uint) {
    pressed = c.LV_EVENT_PRESSED,
    pressing = c.LV_EVENT_PRESSING,
    released = c.LV_EVENT_RELEASED,
    clicked = c.LV_EVENT_CLICKED,
    long_pressed = c.LV_EVENT_LONG_PRESSED,
    long_pressed_repeat = c.LV_EVENT_LONG_PRESSED_REPEAT,
    focused = c.LV_EVENT_FOCUSED,
    defocused = c.LV_EVENT_DEFOCUSED,
    value_changed = c.LV_EVENT_VALUE_CHANGED,
    ready = c.LV_EVENT_READY,
    cancel = c.LV_EVENT_CANCEL,
    scroll = c.LV_EVENT_SCROLL,
    scroll_end = c.LV_EVENT_SCROLL_END,
};

pub const Callback = *const fn (?*c.lv_event_t) callconv(.c) void;

/// Register an event handler on an object
pub fn on(obj: Obj, code: Code, cb: Callback, user_data: ?*anyopaque) void {
    _ = c.lv_obj_add_event_cb(obj.ptr, cb, @intFromEnum(code), user_data);
}

/// Get target object from event
pub fn target(e: *c.lv_event_t) ?Obj {
    return Obj.from(c.lv_event_get_target_obj(e));
}

/// Get user data from event
pub fn userData(e: *c.lv_event_t) ?*anyopaque {
    return c.lv_event_get_user_data(e);
}
