//! HAL Button Matrix Abstraction
//!
//! For matrix keyboards where N GPIOs are scanned to detect M keys.
//! Produces the same `ButtonGroupEvent(ButtonId)` as `button_group`,
//! so Board treats both identically.
//!
//! ## Usage
//!
//! ```zig
//! const ButtonId = enum(u8) { do_, re, mi, fa };
//!
//! const matrix_spec = struct {
//!     pub const Driver = MatrixKeyDriver;  // must have scanKeys(*Self) -> [N]bool
//!     pub const key_count = 4;
//!     pub const meta = .{ .id = "buttons.matrix" };
//! };
//!
//! const Buttons = hal.button_matrix.from(matrix_spec, ButtonId);
//! ```

const std = @import("std");

const button_mod = @import("button.zig");
pub const ButtonAction = button_mod.ButtonAction;

const button_group_mod = @import("button_group.zig");
pub const ButtonGroupEvent = button_group_mod.ButtonGroupEvent;
pub const ButtonGroupConfig = button_group_mod.ButtonGroupConfig;

const _ButtonMatrixMarker = struct {};

/// Check if T is a ButtonMatrix HAL type
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _ButtonMatrixMarker;
}

/// Create a ButtonMatrix HAL type from a spec + ButtonId enum.
///
/// spec must define:
///   - `Driver`: struct with `scanKeys(*Self) [key_count]bool`
///   - `key_count`: comptime_int — number of keys the driver scans
///   - `meta`: .{ .id = "..." }
///
/// ButtonId must be an enum(u8) with exactly key_count fields.
pub fn from(comptime spec: type, comptime ButtonId: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify key_count
        const kc: comptime_int = spec.key_count;
        _ = kc;
        // Verify meta.id
        _ = @as([]const u8, spec.meta.id);
        // Verify scanKeys returns [key_count]bool
        _ = @as(*const fn (*BaseDriver) [spec.key_count]bool, &BaseDriver.scanKeys);
    }

    const Driver = spec.Driver;
    const key_count: comptime_int = spec.key_count;
    const num_buttons = @typeInfo(ButtonId).@"enum".fields.len;

    if (key_count != num_buttons) {
        @compileError("button_matrix: key_count != ButtonId enum field count");
    }

    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        pub const _hal_marker = _ButtonMatrixMarker;
        pub const DriverType = Driver;
        pub const ButtonIdType = ButtonId;

        // ================================================================
        // Metadata
        // ================================================================

        pub const meta = spec.meta;
        pub const Event = ButtonGroupEvent(ButtonId);
        pub const EventCallback = *const fn (?*anyopaque, Event) void;

        const ButtonTracking = struct {
            down_ms: u64 = 0,
            up_ms: u64 = 0,
            last_click_ms: u64 = 0,
            consecutive_clicks: u8 = 0,
            is_pressed: bool = false,
            long_press_fired: bool = false,
        };

        driver: *Driver,
        time_fn: *const fn () u64,
        config: ButtonGroupConfig,

        tracking: [num_buttons]ButtonTracking = [_]ButtonTracking{.{}} ** num_buttons,
        last_raw: u16 = 0, // bitmask of pressed keys

        event_queue: [8]Event = undefined,
        event_count: u8 = 0,
        event_index: u8 = 0,

        running: bool = false,
        event_callback: ?EventCallback = null,
        event_ctx: ?*anyopaque = null,

        pub fn init(driver: *Driver, time_fn: *const fn () u64) Self {
            return Self.initWithConfig(driver, time_fn, .{});
        }

        pub fn initWithConfig(driver: *Driver, time_fn: *const fn () u64, config: ButtonGroupConfig) Self {
            return .{
                .driver = driver,
                .time_fn = time_fn,
                .config = config,
            };
        }

        pub fn setCallback(self: *Self, callback: EventCallback, ctx: ?*anyopaque) void {
            self.event_callback = callback;
            self.event_ctx = ctx;
        }

        /// Poll matrix keys and process state changes
        pub fn poll(self: *Self) void {
            const now_ms = self.time_fn();
            const keys: [key_count]bool = self.driver.scanKeys();

            // Build bitmask for getLastRaw()
            var raw: u16 = 0;
            for (0..key_count) |i| {
                if (keys[i]) raw |= @as(u16, 1) << @intCast(i);
            }
            self.last_raw = raw;

            // Process each key independently
            for (0..key_count) |i| {
                const btn_id: ButtonId = @enumFromInt(i);
                const track = &self.tracking[i];
                const pressed = keys[i];

                if (pressed and !track.is_pressed) {
                    // Press
                    track.is_pressed = true;
                    track.down_ms = now_ms;
                    track.long_press_fired = false;
                    self.queueEvent(.{
                        .source = meta.id,
                        .id = btn_id,
                        .action = .press,
                        .timestamp_ms = now_ms,
                    });
                } else if (!pressed and track.is_pressed) {
                    // Release
                    track.is_pressed = false;
                    track.up_ms = now_ms;
                    const duration: u32 = @intCast(now_ms -| track.down_ms);

                    // Click counting
                    if (track.last_click_ms > 0 and
                        now_ms -| track.last_click_ms <= self.config.click_gap_ms)
                    {
                        track.consecutive_clicks += 1;
                    } else {
                        track.consecutive_clicks = 1;
                    }
                    track.last_click_ms = now_ms;

                    const action: ButtonAction = if (track.consecutive_clicks >= 2)
                        .double_click
                    else
                        .click;

                    self.queueEvent(.{
                        .source = meta.id,
                        .id = btn_id,
                        .action = action,
                        .timestamp_ms = now_ms,
                        .click_count = track.consecutive_clicks,
                        .duration_ms = duration,
                    });
                    self.queueEvent(.{
                        .source = meta.id,
                        .id = btn_id,
                        .action = .release,
                        .timestamp_ms = now_ms,
                        .duration_ms = duration,
                    });
                } else if (pressed and track.is_pressed and !track.long_press_fired) {
                    // Long press check
                    const held_ms = now_ms -| track.down_ms;
                    if (held_ms >= self.config.long_press_ms) {
                        track.long_press_fired = true;
                        self.queueEvent(.{
                            .source = meta.id,
                            .id = btn_id,
                            .action = .long_press,
                            .timestamp_ms = now_ms,
                            .duration_ms = @intCast(held_ms),
                        });
                    }
                }
            }
        }

        pub fn nextEvent(self: *Self) ?Event {
            if (self.event_index < self.event_count) {
                const event = self.event_queue[self.event_index];
                self.event_index += 1;
                return event;
            }
            self.event_count = 0;
            self.event_index = 0;
            return null;
        }

        pub fn isPressed(self: *const Self, id: ButtonId) bool {
            return self.tracking[@intFromEnum(id)].is_pressed;
        }

        pub fn isAnyPressed(self: *const Self) bool {
            for (&self.tracking) |*t| {
                if (t.is_pressed) return true;
            }
            return false;
        }

        pub fn getLastRaw(self: *const Self) u16 {
            return self.last_raw;
        }

        pub fn reset(self: *Self) void {
            for (&self.tracking) |*t| t.* = .{};
            self.last_raw = 0;
            self.event_count = 0;
            self.event_index = 0;
        }

        pub fn stop(self: *Self) void {
            self.running = false;
        }

        pub fn run(self: *Self, sleep_fn: *const fn (u32) void, poll_interval_ms: u32) void {
            self.running = true;
            while (self.running) {
                self.poll();
                sleep_fn(poll_interval_ms);
            }
        }

        pub fn runDefault(self: *Self, sleep_fn: *const fn (u32) void) void {
            self.run(sleep_fn, 10);
        }

        fn queueEvent(self: *Self, event: Event) void {
            if (self.event_callback) |callback| {
                callback(self.event_ctx, event);
                return;
            }
            if (self.event_count < self.event_queue.len) {
                self.event_queue[self.event_count] = event;
                self.event_count += 1;
            }
        }
    };
}
