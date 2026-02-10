//! UI Framework — Zig-friendly LVGL wrapper
//!
//! Bridges LVGL C core with embed-zig's HAL display trait.
//! Provides type-safe, Zig-idiomatic API for embedded UI development.
//!
//! ## Architecture
//!
//! ```
//! ┌──────────────────────────────────────────┐
//! │ Application                              │
//! │   const label = ui.Label.create(screen)  │
//! │   label.setText("Hello!")                 │
//! ├──────────────────────────────────────────┤
//! │ lib/pkg/ui  (this module)                │
//! │   - Display adapter (HAL → LVGL flush)   │
//! │   - Widget wrappers (Label, Button, ...)  │
//! │   - Tick/timer management                │
//! ├──────────────────────────────────────────┤
//! │ third_party/lvgl  (C core, zig-cc)       │
//! ├──────────────────────────────────────────┤
//! │ hal.display  (platform driver)           │
//! └──────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const ui = @import("ui");
//!
//! // Initialize with a HAL display driver
//! var ctx = try ui.init(display_driver, .{});
//! defer ctx.deinit();
//!
//! // Create widgets on the active screen
//! const label = ui.Label.create(ctx.screen());
//! label.setText("Hello LVGL!");
//! label.center();
//!
//! // Main loop
//! while (running) {
//!     ctx.tick(5);
//!     ctx.handler();
//!     sleep(5);
//! }
//! ```

const lvgl = @import("lvgl");
const c = lvgl.c;
const hal = @import("hal");

// Re-export sub-modules
pub const Label = @import("label.zig");
pub const Obj = @import("obj.zig");
pub const MemDisplay = @import("mem_display.zig").MemDisplay;

// ============================================================================
// UI Context
// ============================================================================

/// Options for UI initialization
pub const InitOptions = struct {
    /// Draw buffer size in lines (partial rendering).
    /// Smaller = less RAM, larger = faster rendering.
    /// Default: 10 lines.
    buf_lines: u16 = 10,
};

/// UI Context — manages LVGL lifecycle and display binding.
///
/// Created by `init()`, must be cleaned up with `deinit()`.
/// Only one context should be active at a time (LVGL is single-instance).
pub fn Context(comptime DisplayDriver: type) type {
    return struct {
        const Self = @This();

        display: *DisplayDriver,
        lv_display: *c.lv_display_t,
        buf1: []u8,

        /// Get the active screen object
        pub fn screen(self: *const Self) Obj {
            _ = self;
            return Obj.wrap(c.lv_screen_active());
        }

        /// Report elapsed time to LVGL's tick counter.
        /// Call this periodically with the actual elapsed ms.
        pub fn tick(_: *Self, ms: u32) void {
            c.lv_tick_inc(ms);
        }

        /// Run LVGL's timer handler. Processes redraws and animations.
        /// Returns ms until next call is needed (can be used for sleep).
        pub fn handler(_: *Self) u32 {
            return c.lv_timer_handler();
        }

        /// Deinitialize LVGL and free resources.
        pub fn deinit(self: *Self) void {
            c.lv_deinit();
            // buf1 is stack-allocated or statically allocated, no free needed
            self.* = undefined;
        }
    };
}

/// Initialize LVGL and bind it to a HAL display driver.
///
/// `driver` must be a pointer to a HAL display driver type created by
/// `hal.display.from(spec)`. The driver's lifetime must exceed the
/// UI context's lifetime.
///
/// Returns a Context that manages the LVGL lifecycle.
pub fn init(comptime HalDisplay: type, display: *HalDisplay, opts: InitOptions) !Context(HalDisplay) {
    // Comptime-specialized adapter: creates a C-callable flush callback
    // that captures the HAL display type and driver pointer via statics.
    const Adapter = struct {
        var hal_display: *HalDisplay = undefined;

        /// C-compatible flush callback for LVGL.
        /// Specialized at comptime for the concrete HalDisplay type.
        fn flushCb(
            lv_disp: ?*c.lv_display_t,
            lv_area: ?*const c.lv_area_t,
            px_map: ?*u8,
        ) callconv(.c) void {
            if (lv_area == null or px_map == null) return;

            const area = lv_area.?;
            const hal_area = hal.DisplayArea{
                .x1 = @intCast(area.x1),
                .y1 = @intCast(area.y1),
                .x2 = @intCast(area.x2),
                .y2 = @intCast(area.y2),
            };

            hal_display.flush(hal_area, @ptrCast(px_map.?));

            if (lv_disp) |d| c.lv_display_flush_ready(d);
        }

        var draw_buf: [@as(u32, HalDisplay.width) * @as(u32, HalDisplay.bpp) * 20]u8 = undefined;
    };
    Adapter.hal_display = display;

    // Initialize LVGL core
    c.lv_init();

    // Create LVGL display
    const lv_disp = c.lv_display_create(
        @intCast(HalDisplay.width),
        @intCast(HalDisplay.height),
    ) orelse return error.DisplayCreateFailed;

    // Calculate buffer size
    const buf_lines = opts.buf_lines;
    const line_bytes = @as(u32, HalDisplay.width) * @as(u32, HalDisplay.bpp);
    const buf_size = line_bytes * @as(u32, buf_lines);

    // Set draw buffers (single buffer, partial rendering mode)
    c.lv_display_set_buffers(
        lv_disp,
        &Adapter.draw_buf,
        null,
        @min(buf_size, Adapter.draw_buf.len),
        c.LV_DISPLAY_RENDER_MODE_PARTIAL,
    );

    // Set the comptime-specialized C flush callback
    c.lv_display_set_flush_cb(lv_disp, Adapter.flushCb);

    return .{
        .display = display,
        .lv_display = lv_disp,
        .buf1 = &Adapter.draw_buf,
    };
}

// ============================================================================
// Tests
// ============================================================================

// ============================================================================
// Integration Tests
// ============================================================================

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = Label;
    _ = Obj;
    _ = @import("mem_display.zig");
}

test "LVGL init and deinit" {
    const Disp = MemDisplay(320, 240, .rgb565);
    const HalDisp = hal.display.from(Disp.spec);

    var driver = Disp.create();
    var display = HalDisp.init(&driver);

    var ctx = try init(HalDisp, &display, .{});
    defer ctx.deinit();

    // Should have a valid screen
    const scr = ctx.screen();
    _ = scr.raw(); // Should not crash
}

test "LVGL create label and tick" {
    const Disp = MemDisplay(320, 240, .rgb565);
    const HalDisp = hal.display.from(Disp.spec);

    var driver = Disp.create();
    var display = HalDisp.init(&driver);

    var ctx = try init(HalDisp, &display, .{});
    defer ctx.deinit();

    // Create a label on the active screen
    const label = Label.create(ctx.screen());
    label.setText("Hello LVGL!");
    label.center();

    // Run a few tick/handler cycles to trigger rendering
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        ctx.tick(5);
        _ = ctx.handler();
    }

    // Verify flush was called (LVGL should have rendered something)
    try @import("std").testing.expect(driver.flush_count > 0);
}

test "LVGL multiple widgets" {
    const Disp = MemDisplay(320, 240, .rgb565);
    const HalDisp = hal.display.from(Disp.spec);

    var driver = Disp.create();
    var display = HalDisp.init(&driver);

    var ctx = try init(HalDisp, &display, .{});
    defer ctx.deinit();

    // Create multiple widgets
    const label1 = Label.create(ctx.screen());
    label1.setText("Label 1");
    label1.setPos(10, 10);

    const label2 = Label.create(ctx.screen());
    label2.setText("Label 2");
    label2.setPos(10, 50);

    // Run tick/handler to render
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        ctx.tick(5);
        _ = ctx.handler();
    }

    // Verify rendering happened
    try @import("std").testing.expect(driver.flush_count > 0);

    // Verify framebuffer has content (labels rendered pixels)
    try @import("std").testing.expect(driver.hasAnyContent());
}
