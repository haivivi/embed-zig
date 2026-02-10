//! UI Framework — Zig-native LVGL wrapper
//!
//! Provides type-safe, chainable API for embedded UI development.
//!
//! ## Usage
//!
//! ```zig
//! const ui = @import("ui");
//!
//! // Create objects with chaining
//! const bar = ui.Obj.create(parent).?
//!     .size(240, 54)
//!     .align(.top_mid, 0, 0)
//!     .bgTransparent()
//!     .flexFlow(.row)
//!     .flexMain(.space_between);
//!
//! const lbl = ui.Label.create(bar).?
//!     .text("Hello")
//!     .color(0xffffff)
//!     .font(&lv_font_montserrat_20);
//!
//! const img = ui.Image.create(bar).?
//!     .src(my_png_data)
//!     .align(.center, 0, 0);
//!
//! // Screens
//! const scr = ui.Obj.createScreen().?
//!     .bgColor(0x000000);
//! scr.load(); // or scr.loadAnim(.move_left, 200);
//! ```

const lvgl = @import("lvgl");
const c = lvgl.c;
const hal = @import("hal");

// Widget types
pub const Obj = @import("obj.zig");
pub const Label = @import("label.zig");
pub const Image = @import("image.zig");
pub const MemDisplay = @import("mem_display.zig").MemDisplay;

// Re-export common enums for convenience
pub const Align = Obj.Align;
pub const FlexFlow = Obj.FlexFlow;
pub const FlexAlign = Obj.FlexAlign;
pub const ScreenAnim = Obj.ScreenAnim;

// ============================================================================
// Display Context
// ============================================================================

pub const InitOptions = struct {
    buf_lines: u16 = 10,
};

pub fn Context(comptime DisplayDriver: type) type {
    return struct {
        const Self = @This();

        display: *DisplayDriver,
        lv_display: *c.lv_display_t,

        pub fn screen(self: *const Self) Obj {
            _ = self;
            return Obj{ .ptr = c.lv_screen_active().? };
        }

        pub fn tick(_: *Self, ms: u32) void {
            c.lv_tick_inc(ms);
        }

        pub fn handler(_: *Self) u32 {
            return c.lv_timer_handler();
        }

        pub fn deinit(self: *Self) void {
            c.lv_deinit();
            self.* = undefined;
        }
    };
}

pub fn init(comptime HalDisplay: type, display: *HalDisplay, opts: InitOptions) !Context(HalDisplay) {
    const Adapter = struct {
        var hal_display: *HalDisplay = undefined;

        fn flushCb(
            lv_disp: ?*c.lv_display_t,
            lv_area: ?*const c.lv_area_t,
            px_map: ?*u8,
        ) callconv(.c) void {
            if (lv_area == null or px_map == null) return;
            const area = lv_area.?;
            hal_display.flush(.{
                .x1 = @intCast(area.x1),
                .y1 = @intCast(area.y1),
                .x2 = @intCast(area.x2),
                .y2 = @intCast(area.y2),
            }, @ptrCast(px_map.?));
            if (lv_disp) |d| c.lv_display_flush_ready(d);
        }

        var draw_buf: [@as(u32, HalDisplay.width) * @as(u32, HalDisplay.bpp) * 20]u8 = undefined;
    };
    Adapter.hal_display = display;

    c.lv_init();

    const lv_disp = c.lv_display_create(
        @intCast(HalDisplay.width),
        @intCast(HalDisplay.height),
    ) orelse return error.DisplayCreateFailed;

    const buf_lines = opts.buf_lines;
    const line_bytes = @as(u32, HalDisplay.width) * @as(u32, HalDisplay.bpp);
    const buf_size = line_bytes * @as(u32, buf_lines);

    c.lv_display_set_buffers(
        lv_disp,
        &Adapter.draw_buf,
        null,
        @min(buf_size, Adapter.draw_buf.len),
        c.LV_DISPLAY_RENDER_MODE_PARTIAL,
    );

    c.lv_display_set_flush_cb(lv_disp, Adapter.flushCb);

    return .{
        .display = display,
        .lv_display = lv_disp,
    };
}

// ============================================================================
// Helpers
// ============================================================================

/// Get a hex color value
pub fn color(hex: u32) c.lv_color_t {
    return c.lv_color_hex(hex);
}

// ============================================================================
// Tests
// ============================================================================

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = Obj;
    _ = Label;
    _ = Image;
    _ = @import("mem_display.zig");
}

test "LVGL init and deinit" {
    const Disp = MemDisplay(320, 240, .rgb565);
    const HalDisp = hal.display.from(Disp.spec);

    var driver = Disp.create();
    var display = HalDisp.init(&driver);

    var ctx = try init(HalDisp, &display, .{});
    defer ctx.deinit();

    const scr = ctx.screen();
    _ = scr.raw();
}

test "LVGL create label with chaining" {
    const Disp = MemDisplay(320, 240, .rgb565);
    const HalDisp = hal.display.from(Disp.spec);

    var driver = Disp.create();
    var display = HalDisp.init(&driver);

    var ctx = try init(HalDisp, &display, .{});
    defer ctx.deinit();

    const lbl = Label.create(ctx.screen()).?
        .text("Hello")
        .color(0xffffff)
        .center();

    _ = lbl.raw();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        ctx.tick(5);
        _ = ctx.handler();
    }

    try @import("std").testing.expect(driver.flush_count > 0);
}
