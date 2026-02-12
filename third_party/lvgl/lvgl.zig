//! Zig bindings for LVGL (Light and Versatile Graphics Library)
//!
//! Provides raw C API access via @cImport. Higher-level Zig-friendly
//! wrappers are in lib/pkg/ui/.

pub const c = @cImport({
    @cDefine("LV_CONF_INCLUDE_SIMPLE", "1");
    @cInclude("lvgl.h");
});

// Re-export commonly used types for convenience
pub const lv_obj_t = c.lv_obj_t;
pub const lv_display_t = c.lv_display_t;
pub const lv_color_t = c.lv_color_t;
pub const lv_area_t = c.lv_area_t;

// =============================================================================
// Initialization
// =============================================================================

pub fn init() void {
    c.lv_init();
}

pub fn deinit() void {
    c.lv_deinit();
}

// =============================================================================
// Tick & Timer
// =============================================================================

/// Report elapsed milliseconds to LVGL's internal tick counter.
/// Must be called periodically (e.g., from a timer interrupt or main loop).
pub fn tickInc(ms: u32) void {
    c.lv_tick_inc(ms);
}

/// Run LVGL's timer handler. Processes pending redraws and animations.
/// Call this in your main loop after tickInc().
pub fn timerHandler() u32 {
    return c.lv_timer_handler();
}

// =============================================================================
// Display
// =============================================================================

pub const FlushCb = *const fn (?*c.lv_display_t, ?*const c.lv_area_t, ?*u8) callconv(.c) void;

/// Create a new display with the given resolution.
pub fn displayCreate(hor_res: i32, ver_res: i32) ?*c.lv_display_t {
    return c.lv_display_create(hor_res, ver_res);
}

/// Set the flush callback for a display.
pub fn displaySetFlushCb(disp: *c.lv_display_t, cb: FlushCb) void {
    c.lv_display_set_flush_cb(disp, cb);
}

/// Set display draw buffers.
pub fn displaySetBuffers(
    disp: *c.lv_display_t,
    buf1: [*]u8,
    buf2: ?[*]u8,
    buf_size_bytes: u32,
    render_mode: c.lv_display_render_mode_t,
) void {
    c.lv_display_set_buffers(disp, buf1, buf2, buf_size_bytes, render_mode);
}

/// Signal that flushing is complete.
pub fn displayFlushReady(disp: *c.lv_display_t) void {
    c.lv_display_flush_ready(disp);
}

/// Get the active screen of a display.
pub fn displayGetScreenActive(disp: ?*c.lv_display_t) ?*c.lv_obj_t {
    return c.lv_display_get_screen_active(disp);
}

// =============================================================================
// Objects
// =============================================================================

/// Get the active screen of the default display.
pub fn screenActive() ?*c.lv_obj_t {
    return c.lv_screen_active();
}

// =============================================================================
// Label Widget
// =============================================================================

pub fn labelCreate(parent: ?*c.lv_obj_t) ?*c.lv_obj_t {
    return c.lv_label_create(parent);
}

pub fn labelSetText(label: *c.lv_obj_t, text: [*:0]const u8) void {
    c.lv_label_set_text(label, text);
}

// =============================================================================
// Obj Alignment
// =============================================================================

pub fn objAlign(obj: *c.lv_obj_t, alignment: c.lv_align_t, x_ofs: i32, y_ofs: i32) void {
    c.lv_obj_align(obj, alignment, x_ofs, y_ofs);
}

pub fn objSetSize(obj: *c.lv_obj_t, w: i32, h: i32) void {
    c.lv_obj_set_size(obj, w, h);
}

pub fn objSetPos(obj: *c.lv_obj_t, x: i32, y: i32) void {
    c.lv_obj_set_pos(obj, x, y);
}

pub fn objDel(obj: *c.lv_obj_t) void {
    c.lv_obj_delete(obj);
}

// =============================================================================
// Color Helpers
// =============================================================================

pub fn colorHex(hex: u32) c.lv_color_t {
    return c.lv_color_hex(hex);
}

pub fn colorWhite() c.lv_color_t {
    return c.lv_color_white();
}

pub fn colorBlack() c.lv_color_t {
    return c.lv_color_black();
}
