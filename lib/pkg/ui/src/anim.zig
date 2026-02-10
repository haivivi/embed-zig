//! LVGL Animation API
//!
//! ```zig
//! ui.anim.run(.{
//!     .obj = my_obj,
//!     .prop = .x,
//!     .from = 0,
//!     .to = 100,
//!     .duration = 300,
//! });
//! ```

const c = @import("lvgl").c;
const Obj = @import("obj.zig");

pub const AnimPath = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
    overshoot,
    bounce,
};

pub const Options = struct {
    obj: ?Obj = null,
    from: i32 = 0,
    to: i32 = 0,
    duration: u32 = 300,
    delay: u32 = 0,
    path: AnimPath = .ease_in_out,
    repeat_count: u32 = 0, // LV_ANIM_REPEAT_INFINITE = 0xFFFF
    exec_cb: ?*const fn (?*anyopaque, i32) callconv(.c) void = null,
    user_data: ?*anyopaque = null,
};

pub fn run(opts: Options) void {
    var a: c.lv_anim_t = undefined;
    c.lv_anim_init(&a);

    if (opts.obj) |o| c.lv_anim_set_var(&a, o.ptr);
    if (opts.exec_cb) |cb| c.lv_anim_set_exec_cb(&a, cb);

    c.lv_anim_set_values(&a, opts.from, opts.to);
    c.lv_anim_set_duration(&a, @intCast(opts.duration));
    c.lv_anim_set_delay(&a, @intCast(opts.delay));

    if (opts.repeat_count > 0) {
        c.lv_anim_set_repeat_count(&a, @intCast(opts.repeat_count));
    }

    switch (opts.path) {
        .linear => c.lv_anim_set_path_cb(&a, c.lv_anim_path_linear),
        .ease_in => c.lv_anim_set_path_cb(&a, c.lv_anim_path_ease_in),
        .ease_out => c.lv_anim_set_path_cb(&a, c.lv_anim_path_ease_out),
        .ease_in_out => c.lv_anim_set_path_cb(&a, c.lv_anim_path_ease_in_out),
        .overshoot => c.lv_anim_set_path_cb(&a, c.lv_anim_path_overshoot),
        .bounce => c.lv_anim_set_path_cb(&a, c.lv_anim_path_bounce),
    }

    _ = c.lv_anim_start(&a);
}

pub const REPEAT_INFINITE: u32 = 0xFFFF;
