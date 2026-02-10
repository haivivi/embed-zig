//! LVGL Object — Zig-native wrapper
//!
//! Base type for all LVGL widgets. Provides chainable API for
//! size, alignment, styles, layout, scrolling, flags, and screens.
//!
//! ```zig
//! const bar = ui.Obj.create(parent).?
//!     .size(240, 54)
//!     .setAlign(.top_mid, 0, 0)
//!     .bg(.{ .transparent = true })
//!     .pad(.{ .left = 16, .right = 16 })
//!     .flex(.{ .flow = .row, .main = .space_between });
//! ```

const c = @import("lvgl").c;
pub const color_mod = @import("color.zig");
pub const font_mod = @import("font.zig");

const Self = @This();

ptr: *c.lv_obj_t,

// ============================================================================
// Creation
// ============================================================================

pub fn create(parent: ?*c.lv_obj_t) ?Self {
    const p = c.lv_obj_create(parent orelse return null) orelse return null;
    return .{ .ptr = p };
}

pub fn createScreen() ?Self {
    const p = c.lv_obj_create(null) orelse return null;
    return .{ .ptr = p };
}

pub fn from(p: ?*c.lv_obj_t) ?Self {
    return if (p) |ptr| Self{ .ptr = ptr } else null;
}

pub fn raw(self: Self) *c.lv_obj_t {
    return self.ptr;
}

// ============================================================================
// Size & Position
// ============================================================================

pub fn size(self: Self, w: i32, h: i32) Self {
    c.lv_obj_set_size(self.ptr, w, h);
    return self;
}

pub fn width(self: Self, w: i32) Self {
    c.lv_obj_set_width(self.ptr, w);
    return self;
}

pub fn height(self: Self, h: i32) Self {
    c.lv_obj_set_height(self.ptr, h);
    return self;
}

pub fn pos(self: Self, x: i32, y: i32) Self {
    c.lv_obj_set_pos(self.ptr, x, y);
    return self;
}

// ============================================================================
// Alignment
// ============================================================================

pub const Align = enum(c_uint) {
    top_left = c.LV_ALIGN_TOP_LEFT,
    top_mid = c.LV_ALIGN_TOP_MID,
    top_right = c.LV_ALIGN_TOP_RIGHT,
    left_mid = c.LV_ALIGN_LEFT_MID,
    center = c.LV_ALIGN_CENTER,
    right_mid = c.LV_ALIGN_RIGHT_MID,
    bottom_left = c.LV_ALIGN_BOTTOM_LEFT,
    bottom_mid = c.LV_ALIGN_BOTTOM_MID,
    bottom_right = c.LV_ALIGN_BOTTOM_RIGHT,
};

pub fn setAlign(self: Self, a: Align, x_ofs: i32, y_ofs: i32) Self {
    c.lv_obj_align(self.ptr, @intFromEnum(a), x_ofs, y_ofs);
    return self;
}

pub fn center(self: Self) Self {
    c.lv_obj_center(self.ptr);
    return self;
}

// ============================================================================
// Background — struct-based
// ============================================================================

pub const BgOptions = struct {
    color: ?u32 = null,
    opa: ?u8 = null,
    image: ?*const anyopaque = null,
    transparent: bool = false,
};

    pub fn bg(self: Self, opts: BgOptions) Self {
        if (opts.transparent) {
            c.lv_obj_set_style_bg_opa(self.ptr, 0, 0);
            return self;
        }
        if (opts.color) |v| c.lv_obj_set_style_bg_color(self.ptr, c.lv_color_hex(v), 0);
        if (opts.opa) |v| c.lv_obj_set_style_bg_opa(self.ptr, v, 0);
        if (opts.image) |v| c.lv_obj_set_style_bg_image_src(self.ptr, v, 0);
        return self;
    }

// Single-value shortcuts
pub fn bgColor(self: Self, hex: u32) Self { c.lv_obj_set_style_bg_color(self.ptr, c.lv_color_hex(hex), 0); return self; }
pub fn bgOpa(self: Self, opa: u8) Self { c.lv_obj_set_style_bg_opa(self.ptr, opa, 0); return self; }
pub fn bgImage(self: Self, src: ?*const anyopaque) Self { c.lv_obj_set_style_bg_image_src(self.ptr, src, 0); return self; }
pub fn bgTransparent(self: Self) Self { return self.bg(.{ .transparent = true }).borderWidth(0).radius(0).padAll(0).scrollbarOff(); }

// ============================================================================
// Padding — struct-based
// ============================================================================

pub const PadOptions = struct {
    all: ?i32 = null,
    left: ?i32 = null,
    right: ?i32 = null,
    top: ?i32 = null,
    bottom: ?i32 = null,
    hor: ?i32 = null,
    ver: ?i32 = null,
    row: ?i32 = null,
    column: ?i32 = null,
};

pub fn pad(self: Self, opts: PadOptions) Self {
    if (opts.all) |v| c.lv_obj_set_style_pad_all(self.ptr, v, 0);
    if (opts.left) |v| c.lv_obj_set_style_pad_left(self.ptr, v, 0);
    if (opts.right) |v| c.lv_obj_set_style_pad_right(self.ptr, v, 0);
    if (opts.top) |v| c.lv_obj_set_style_pad_top(self.ptr, v, 0);
    if (opts.bottom) |v| c.lv_obj_set_style_pad_bottom(self.ptr, v, 0);
    if (opts.hor) |v| c.lv_obj_set_style_pad_hor(self.ptr, v, 0);
    if (opts.ver) |v| c.lv_obj_set_style_pad_ver(self.ptr, v, 0);
    if (opts.row) |v| c.lv_obj_set_style_pad_row(self.ptr, v, 0);
    if (opts.column) |v| c.lv_obj_set_style_pad_column(self.ptr, v, 0);
    return self;
}

// Single-value shortcuts (still available for chaining)
pub fn padAll(self: Self, p: i32) Self { c.lv_obj_set_style_pad_all(self.ptr, p, 0); return self; }
pub fn padLeft(self: Self, p: i32) Self { c.lv_obj_set_style_pad_left(self.ptr, p, 0); return self; }
pub fn padRight(self: Self, p: i32) Self { c.lv_obj_set_style_pad_right(self.ptr, p, 0); return self; }
pub fn padTop(self: Self, p: i32) Self { c.lv_obj_set_style_pad_top(self.ptr, p, 0); return self; }
pub fn padBottom(self: Self, p: i32) Self { c.lv_obj_set_style_pad_bottom(self.ptr, p, 0); return self; }
pub fn padHor(self: Self, p: i32) Self { c.lv_obj_set_style_pad_hor(self.ptr, p, 0); return self; }
pub fn padVer(self: Self, p: i32) Self { c.lv_obj_set_style_pad_ver(self.ptr, p, 0); return self; }
pub fn padRow(self: Self, p: i32) Self { c.lv_obj_set_style_pad_row(self.ptr, p, 0); return self; }
pub fn padColumn(self: Self, p: i32) Self { c.lv_obj_set_style_pad_column(self.ptr, p, 0); return self; }

// ============================================================================
// Border — struct-based
// ============================================================================

pub const BorderOptions = struct {
    width: ?i32 = null,
    color: ?u32 = null,
    opa: ?u8 = null,
};

pub fn border(self: Self, opts: BorderOptions) Self {
    if (opts.width) |v| c.lv_obj_set_style_border_width(self.ptr, v, 0);
    if (opts.color) |hex| c.lv_obj_set_style_border_color(self.ptr, c.lv_color_hex(hex), 0);
    if (opts.opa) |o| c.lv_obj_set_style_border_opa(self.ptr, o, 0);
    return self;
}

pub fn borderWidth(self: Self, w: i32) Self { c.lv_obj_set_style_border_width(self.ptr, w, 0); return self; }

// ============================================================================
// Radius & Opacity
// ============================================================================

    pub fn radius(self: Self, r: i32) Self { c.lv_obj_set_style_radius(self.ptr, r, 0); return self; }
    pub fn setOpa(self: Self, o: u8) Self { c.lv_obj_set_style_opa(self.ptr, o, 0); return self; }

// ============================================================================
// Text style
// ============================================================================

pub const TextOptions = struct {
    color: ?u32 = null,
    font: ?*const c.lv_font_t = null,
    align_: ?u8 = null,
    line_space: ?i32 = null,
    letter_space: ?i32 = null,
};

pub fn textStyle(self: Self, opts: TextOptions) Self {
    if (opts.color) |hex| c.lv_obj_set_style_text_color(self.ptr, c.lv_color_hex(hex), 0);
    if (opts.font) |f| c.lv_obj_set_style_text_font(self.ptr, f, 0);
    if (opts.line_space) |v| c.lv_obj_set_style_text_line_space(self.ptr, v, 0);
    if (opts.letter_space) |v| c.lv_obj_set_style_text_letter_space(self.ptr, v, 0);
    return self;
}

pub fn textColor(self: Self, hex: u32) Self { c.lv_obj_set_style_text_color(self.ptr, c.lv_color_hex(hex), 0); return self; }
pub fn textFont(self: Self, f: *const c.lv_font_t) Self { c.lv_obj_set_style_text_font(self.ptr, f, 0); return self; }

// ============================================================================
// Flex Layout — struct-based
// ============================================================================

pub const FlexFlow = enum(c_uint) {
    row = c.LV_FLEX_FLOW_ROW,
    column = c.LV_FLEX_FLOW_COLUMN,
    row_wrap = c.LV_FLEX_FLOW_ROW_WRAP,
    column_wrap = c.LV_FLEX_FLOW_COLUMN_WRAP,
};

pub const FlexAlign = enum(c_uint) {
    start = c.LV_FLEX_ALIGN_START,
    end_ = c.LV_FLEX_ALIGN_END,
    center = c.LV_FLEX_ALIGN_CENTER,
    space_between = c.LV_FLEX_ALIGN_SPACE_BETWEEN,
    space_around = c.LV_FLEX_ALIGN_SPACE_AROUND,
    space_evenly = c.LV_FLEX_ALIGN_SPACE_EVENLY,
};

pub const FlexOptions = struct {
    flow: ?FlexFlow = null,
    main: ?FlexAlign = null,
    cross: ?FlexAlign = null,
    grow: ?u8 = null,
};

pub fn flex(self: Self, opts: FlexOptions) Self {
    if (opts.flow) |f| c.lv_obj_set_flex_flow(self.ptr, @intFromEnum(f));
    if (opts.main) |a| c.lv_obj_set_style_flex_main_place(self.ptr, @intFromEnum(a), 0);
    if (opts.cross) |a| c.lv_obj_set_style_flex_cross_place(self.ptr, @intFromEnum(a), 0);
    if (opts.grow) |g| c.lv_obj_set_flex_grow(self.ptr, g);
    return self;
}

// Single-value shortcuts
pub fn flexFlow(self: Self, flow: FlexFlow) Self { c.lv_obj_set_flex_flow(self.ptr, @intFromEnum(flow)); return self; }
pub fn flexGrow(self: Self, grow: u8) Self { c.lv_obj_set_flex_grow(self.ptr, grow); return self; }
pub fn flexMain(self: Self, a: FlexAlign) Self { c.lv_obj_set_style_flex_main_place(self.ptr, @intFromEnum(a), 0); return self; }
pub fn flexCross(self: Self, a: FlexAlign) Self { c.lv_obj_set_style_flex_cross_place(self.ptr, @intFromEnum(a), 0); return self; }

// ============================================================================
// Scrolling
// ============================================================================

pub fn scrollbarOff(self: Self) Self { c.lv_obj_set_scrollbar_mode(self.ptr, c.LV_SCROLLBAR_MODE_OFF); return self; }
pub fn scrollSnapX(self: Self) Self { c.lv_obj_set_scroll_snap_x(self.ptr, c.LV_SCROLL_SNAP_CENTER); return self; }
pub fn scrollToView(self: Self, anim: bool) void { c.lv_obj_scroll_to_view(self.ptr, if (anim) c.LV_ANIM_ON else c.LV_ANIM_OFF); }

// ============================================================================
// Flags
// ============================================================================

pub fn hide(self: Self) Self { c.lv_obj_add_flag(self.ptr, c.LV_OBJ_FLAG_HIDDEN); return self; }
pub fn show(self: Self) Self { c.lv_obj_clear_flag(self.ptr, c.LV_OBJ_FLAG_HIDDEN); return self; }
pub fn setHidden(self: Self, hidden: bool) Self { return if (hidden) self.hide() else self.show(); }
pub fn clickable(self: Self, v: bool) Self {
    if (v) c.lv_obj_add_flag(self.ptr, c.LV_OBJ_FLAG_CLICKABLE)
    else c.lv_obj_clear_flag(self.ptr, c.LV_OBJ_FLAG_CLICKABLE);
    return self;
}

// ============================================================================
// Lifecycle
// ============================================================================

pub fn delete(self: Self) void { c.lv_obj_delete(self.ptr); }
pub fn invalidate(self: Self) void { c.lv_obj_invalidate(self.ptr); }

// ============================================================================
// Screen
// ============================================================================

pub fn load(self: Self) void { c.lv_screen_load(self.ptr); }

pub const ScreenAnim = enum(c_uint) {
    none = c.LV_SCR_LOAD_ANIM_NONE,
    fade_in = c.LV_SCR_LOAD_ANIM_FADE_IN,
    move_left = c.LV_SCR_LOAD_ANIM_MOVE_LEFT,
    move_right = c.LV_SCR_LOAD_ANIM_MOVE_RIGHT,
    move_top = c.LV_SCR_LOAD_ANIM_MOVE_TOP,
    move_bottom = c.LV_SCR_LOAD_ANIM_MOVE_BOTTOM,
};

pub fn loadAnim(self: Self, anim: ScreenAnim, time_ms: u32) void {
    c.lv_screen_load_anim(self.ptr, @intFromEnum(anim), @intCast(time_ms), 0, false);
}

// ============================================================================
// Children
// ============================================================================

pub fn childCount(self: Self) u32 { return c.lv_obj_get_child_count(self.ptr); }
pub fn child(self: Self, idx: i32) ?Self { return from(c.lv_obj_get_child(self.ptr, idx)); }
