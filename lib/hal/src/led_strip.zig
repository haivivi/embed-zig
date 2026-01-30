//! RGB LED Strip Hardware Abstraction Layer
//!
//! Provides a platform-independent interface for RGB LED strip control:
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   board.led_strip.setColor(Color.red)  │
//! ├─────────────────────────────────────────┤
//! │ RgbLedStrip(spec)  ← HAL wrapper        │
//! │   - brightness control                  │
//! │   - animation support                   │
//! │   - overlay effects                     │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← hardware impl  │
//! │   - setPixel()                          │
//! │   - getPixelCount()                     │
//! │   - refresh() [optional]                │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // Define spec with driver and metadata
//! const led_spec = struct {
//!     pub const Driver = MyLedDriver;
//!     pub const meta = hal.spec.Meta{ .id = "led.main" };
//! };
//!
//! // Create HAL wrapper
//! const MyLedStrip = hal.RgbLedStrip(led_spec);
//! var led = MyLedStrip.init(&driver_instance);
//!
//! // Use unified interface
//! led.setColor(Color.red);
//! led.setBrightness(128);
//! ```
//!
//! ## Features
//!
//! - Keyframe-based animation with per-frame duration and easing
//! - Multiple easing curves (linear, ease-in, ease-out, cubic, etc.)
//! - Comptime effect generators for common patterns
//! - Overlay support for temporary effects (e.g., NFC feedback)
//! - Independent brightness and enable control

const std = @import("std");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _RgbLedStripMarker = struct {};

/// Check if a type is a RgbLedStrip peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _RgbLedStripMarker;
}

// ============================================================================
// Color Type
// ============================================================================

/// RGB color value
pub const Color = packed struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    // Predefined colors
    pub const black = Color{};
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };
    pub const red = Color{ .r = 255 };
    pub const green = Color{ .g = 255 };
    pub const blue = Color{ .b = 255 };
    pub const yellow = Color{ .r = 255, .g = 255 };
    pub const cyan = Color{ .g = 255, .b = 255 };
    pub const magenta = Color{ .r = 255, .b = 255 };
    pub const orange = Color{ .r = 255, .g = 128 };
    pub const purple = Color{ .r = 128, .b = 255 };

    /// Create color from RGB values
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    /// Create color from HSV values (h: 0-255, s: 0-255, v: 0-255)
    pub fn hsv(h: u8, s: u8, v: u8) Color {
        if (s == 0) {
            return .{ .r = v, .g = v, .b = v };
        }

        const region = h / 43;
        const remainder = (h - (region * 43)) * 6;

        const p: u8 = @intCast((@as(u16, v) * (255 - s)) >> 8);
        const q: u8 = @intCast((@as(u16, v) * (255 - ((@as(u16, s) * remainder) >> 8))) >> 8);
        const t: u8 = @intCast((@as(u16, v) * (255 - ((@as(u16, s) * (255 - remainder)) >> 8))) >> 8);

        return switch (region) {
            0 => .{ .r = v, .g = t, .b = p },
            1 => .{ .r = q, .g = v, .b = p },
            2 => .{ .r = p, .g = v, .b = t },
            3 => .{ .r = p, .g = q, .b = v },
            4 => .{ .r = t, .g = p, .b = v },
            else => .{ .r = v, .g = p, .b = q },
        };
    }

    /// Apply brightness multiplier (0-255), returns new color
    pub fn withBrightness(self: Color, brightness: u8) Color {
        return .{
            .r = @intCast((@as(u16, self.r) * brightness) / 255),
            .g = @intCast((@as(u16, self.g) * brightness) / 255),
            .b = @intCast((@as(u16, self.b) * brightness) / 255),
        };
    }

    /// Linear interpolation between two colors
    pub fn lerp(a: Color, b: Color, t: u8) Color {
        const inv_t = 255 - t;
        return .{
            .r = @intCast((@as(u16, a.r) * inv_t + @as(u16, b.r) * t) / 255),
            .g = @intCast((@as(u16, a.g) * inv_t + @as(u16, b.g) * t) / 255),
            .b = @intCast((@as(u16, a.b) * inv_t + @as(u16, b.b) * t) / 255),
        };
    }

    /// Check if color is black (all zeros)
    pub fn isBlack(self: Color) bool {
        return self.r == 0 and self.g == 0 and self.b == 0;
    }

    /// Pack to u32 (0x00RRGGBB)
    pub fn toU32(self: Color) u32 {
        return (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | self.b;
    }
};

// ============================================================================
// Easing Functions
// ============================================================================

/// Easing curve type for frame transitions
pub const Easing = enum(u8) {
    /// No transition - instant switch
    none = 0,
    /// Linear interpolation
    linear = 1,
    /// Quadratic ease-in (slow start)
    ease_in = 2,
    /// Quadratic ease-out (slow end)
    ease_out = 3,
    /// Quadratic ease-in-out (slow start and end)
    ease_in_out = 4,
    /// Cubic ease-in (slower start)
    cubic_in = 5,
    /// Cubic ease-out (slower end)
    cubic_out = 6,
    /// Cubic ease-in-out
    cubic_in_out = 7,

    /// Apply easing function to t (0-255) -> (0-255)
    pub fn apply(self: Easing, t: u8) u8 {
        return switch (self) {
            .none => if (t >= 128) 255 else 0,
            .linear => t,
            .ease_in => easeInQuad(t),
            .ease_out => easeOutQuad(t),
            .ease_in_out => easeInOutQuad(t),
            .cubic_in => easeInCubic(t),
            .cubic_out => easeOutCubic(t),
            .cubic_in_out => easeInOutCubic(t),
        };
    }

    // Quadratic easing (t^2)
    fn easeInQuad(t: u8) u8 {
        // t^2 / 255
        const t16: u16 = t;
        return @intCast((t16 * t16) / 255);
    }

    fn easeOutQuad(t: u8) u8 {
        // 1 - (1-t)^2
        const inv = 255 - t;
        const inv16: u16 = inv;
        return 255 - @as(u8, @intCast((inv16 * inv16) / 255));
    }

    fn easeInOutQuad(t: u8) u8 {
        if (t < 128) {
            // 2 * t^2 for first half
            const t16: u16 = t;
            return @intCast((t16 * t16 * 2) / 255);
        } else {
            // 1 - 2 * (1-t)^2 for second half
            const inv = 255 - t;
            const inv16: u16 = inv;
            return 255 - @as(u8, @intCast((inv16 * inv16 * 2) / 255));
        }
    }

    // Cubic easing (t^3)
    fn easeInCubic(t: u8) u8 {
        // t^3 / 255^2
        const t32: u32 = t;
        return @intCast((t32 * t32 * t32) / (255 * 255));
    }

    fn easeOutCubic(t: u8) u8 {
        // 1 - (1-t)^3
        const inv = 255 - t;
        const inv32: u32 = inv;
        return 255 - @as(u8, @intCast((inv32 * inv32 * inv32) / (255 * 255)));
    }

    fn easeInOutCubic(t: u8) u8 {
        if (t < 128) {
            // 4 * t^3 for first half
            const t32: u32 = t;
            return @intCast((t32 * t32 * t32 * 4) / (255 * 255));
        } else {
            // 1 - 4 * (1-t)^3 for second half
            const inv = 255 - t;
            const inv32: u32 = inv;
            return 255 - @as(u8, @intCast((inv32 * inv32 * inv32 * 4) / (255 * 255)));
        }
    }
};

// ============================================================================
// Keyframe and Animation Types
// ============================================================================

/// Single keyframe with colors, duration, and easing to next frame
pub fn Keyframe(comptime led_count: usize) type {
    return struct {
        const Self = @This();

        colors: [led_count]Color,
        duration_ms: u16, // How long to transition to this frame (0xFFFF = forever/static)
        easing: Easing = .none, // Easing curve for transition TO this frame

        /// Create keyframe with solid color (no easing)
        pub fn solid(color: Color, duration_ms: u16) Self {
            return .{
                .colors = [_]Color{color} ** led_count,
                .duration_ms = duration_ms,
                .easing = .none,
            };
        }

        /// Create keyframe with solid color and easing
        pub fn solidEased(color: Color, duration_ms: u16, easing: Easing) Self {
            return .{
                .colors = [_]Color{color} ** led_count,
                .duration_ms = duration_ms,
                .easing = easing,
            };
        }

        /// Create keyframe from color array (no easing)
        pub fn fromColors(colors: [led_count]Color, duration_ms: u16) Self {
            return .{
                .colors = colors,
                .duration_ms = duration_ms,
                .easing = .none,
            };
        }

        /// Create keyframe from color array with easing
        pub fn fromColorsEased(colors: [led_count]Color, duration_ms: u16, easing: Easing) Self {
            return .{
                .colors = colors,
                .duration_ms = duration_ms,
                .easing = easing,
            };
        }
    };
}

/// Animation containing multiple keyframes
pub fn Animation(comptime max_frames: usize, comptime led_count: usize) type {
    return struct {
        const Self = @This();
        pub const KF = Keyframe(led_count);

        frames: [max_frames]KF = undefined,
        frame_count: u8 = 0,
        loop: bool = true,

        /// Initialize from comptime keyframe slice
        pub fn init(comptime keyframes: []const KF, loop: bool) Self {
            var self = Self{ .loop = loop };
            self.frame_count = @intCast(keyframes.len);
            for (keyframes, 0..) |kf, i| {
                self.frames[i] = kf;
            }
            return self;
        }

        /// Add a frame at runtime
        pub fn addFrame(self: *Self, frame: KF) bool {
            if (self.frame_count >= max_frames) return false;
            self.frames[self.frame_count] = frame;
            self.frame_count += 1;
            return true;
        }

        /// Add a solid color frame at runtime
        pub fn addSolid(self: *Self, color: Color, duration_ms: u16) bool {
            return self.addFrame(KF.solid(color, duration_ms));
        }

        /// Clear all frames
        pub fn clear(self: *Self) void {
            self.frame_count = 0;
        }

        /// Check if animation is empty
        pub fn isEmpty(self: Self) bool {
            return self.frame_count == 0;
        }
    };
}

// ============================================================================
// Comptime Effect Generators
// ============================================================================

/// Effect generators for common LED patterns (all comptime)
pub fn Effects(comptime led_count: usize) type {
    return struct {
        const KF = Keyframe(led_count);

        /// Solid color (single frame, infinite duration)
        pub fn solid(color: Color) [1]KF {
            return .{KF.solid(color, 0xFFFF)};
        }

        /// Breathing effect with smooth easing (fade in/out)
        pub fn breathing(
            comptime color: Color,
            comptime fade_in_ms: u16,
            comptime fade_out_ms: u16,
        ) [2]KF {
            return .{
                KF.solidEased(color, fade_in_ms, .ease_in_out),
                KF.solidEased(Color.black, fade_out_ms, .ease_in_out),
            };
        }

        /// Breathing effect with custom easing
        pub fn breathingEased(
            comptime color: Color,
            comptime fade_in_ms: u16,
            comptime fade_out_ms: u16,
            comptime easing: Easing,
        ) [2]KF {
            return .{
                KF.solidEased(color, fade_in_ms, easing),
                KF.solidEased(Color.black, fade_out_ms, easing),
            };
        }

        /// Flash effect (quick blink, no easing)
        pub fn flash(comptime color: Color, comptime interval_ms: u16) [2]KF {
            return .{
                KF.solid(color, interval_ms),
                KF.solid(Color.black, interval_ms),
            };
        }

        /// Pulse effect with smooth transition
        pub fn pulse(
            comptime color: Color,
            comptime duration_ms: u16,
        ) [2]KF {
            return .{
                KF.solidEased(color, duration_ms / 2, .ease_out),
                KF.solidEased(Color.black, duration_ms / 2, .ease_in),
            };
        }

        /// Gradient from one color to another across LEDs
        pub fn gradient(comptime start: Color, comptime to: Color) [led_count]Color {
            var colors: [led_count]Color = undefined;
            for (0..led_count) |i| {
                const t: u8 = if (led_count > 1)
                    @intCast((i * 255) / (led_count - 1))
                else
                    0;
                colors[i] = Color.lerp(start, to, t);
            }
            return colors;
        }

        /// Rainbow colors across LEDs
        pub fn rainbow(comptime saturation: u8, comptime value: u8) [led_count]Color {
            var colors: [led_count]Color = undefined;
            for (0..led_count) |i| {
                const hue: u8 = @intCast((i * 255) / led_count);
                colors[i] = Color.hsv(hue, saturation, value);
            }
            return colors;
        }

        /// Split colors (first half one color, second half another)
        pub fn split(comptime color1: Color, comptime color2: Color) [led_count]Color {
            var colors: [led_count]Color = undefined;
            const half = led_count / 2;
            for (0..led_count) |i| {
                colors[i] = if (i < half) color1 else color2;
            }
            return colors;
        }

        /// Progress bar (lit LEDs up to percentage)
        pub fn progress(comptime fg: Color, comptime bg: Color, percent: u8) [led_count]Color {
            var colors: [led_count]Color = undefined;
            const lit_count = (@as(usize, percent) * led_count) / 100;
            for (0..led_count) |i| {
                colors[i] = if (i < lit_count) fg else bg;
            }
            return colors;
        }

        /// Chase animation frames (single LED moving)
        pub fn chase(
            comptime fg: Color,
            comptime bg: Color,
            comptime frame_ms: u16,
        ) [led_count]KF {
            var frames: [led_count]KF = undefined;
            for (0..led_count) |frame_idx| {
                var colors: [led_count]Color = [_]Color{bg} ** led_count;
                colors[frame_idx] = fg;
                frames[frame_idx] = .{
                    .colors = colors,
                    .duration_ms = frame_ms,
                };
            }
            return frames;
        }

        /// Rotate animation (rainbow rotation)
        pub fn rainbowRotate(
            comptime saturation: u8,
            comptime value: u8,
            comptime frame_ms: u16,
        ) [led_count]KF {
            var frames: [led_count]KF = undefined;
            for (0..led_count) |offset| {
                var colors: [led_count]Color = undefined;
                for (0..led_count) |i| {
                    const pos = (i + offset) % led_count;
                    const hue: u8 = @intCast((pos * 255) / led_count);
                    colors[i] = Color.hsv(hue, saturation, value);
                }
                frames[offset] = .{
                    .colors = colors,
                    .duration_ms = frame_ms,
                };
            }
            return frames;
        }
    };
}

// ============================================================================
// LedStrip HAL Wrapper
// ============================================================================

/// RGB LED Strip HAL component
///
/// Wraps a low-level Driver and provides:
/// - Unified setColor/setPixel interface
/// - Brightness control
/// - Animation support with easing
/// - Overlay effects
///
/// spec must define:
/// - `Driver`: struct with setPixel, getPixelCount methods
/// - `meta`: spec.Meta with component id
///
/// Example:
/// ```zig
/// const led_spec = struct {
///     pub const Driver = Tca9554LedDriver;
///     pub const meta = hal.spec.Meta{ .id = "led.main" };
/// };
/// const MyLed = led_strip.from(led_spec);
/// ```
pub fn from(comptime spec: type) type {
    comptime {
        // Handle pointer types
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify Driver.setPixel exists and has correct arity
        // We use duck typing for Color - any struct with r, g, b fields works
        if (!@hasDecl(BaseDriver, "setPixel")) {
            @compileError("Driver must have setPixel method");
        }
        // Verify Driver.getPixelCount signature
        _ = @as(*const fn (*BaseDriver) u32, &BaseDriver.getPixelCount);
        // Verify meta.id
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _RgbLedStripMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// The underlying driver instance
        driver: *Driver,

        /// Global brightness (0-255)
        brightness: u8 = 255,

        /// Enable/disable output
        enabled: bool = true,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        // ----- Basic Control -----

        /// Get number of LEDs/pixels
        pub fn getPixelCount(self: *Self) u32 {
            return self.driver.getPixelCount();
        }

        /// Set a single pixel color (with brightness applied)
        pub fn setPixel(self: *Self, index: u32, color: Color) void {
            if (!self.enabled) return;
            const adjusted = if (self.brightness < 255)
                color.withBrightness(self.brightness)
            else
                color;
            // Convert to driver's color type (may be different from hal.Color)
            const DriverColorType = @typeInfo(@TypeOf(Driver.setPixel)).@"fn".params[2].type.?;
            self.driver.setPixel(index, DriverColorType{ .r = adjusted.r, .g = adjusted.g, .b = adjusted.b });
        }

        /// Set all pixels to the same color
        pub fn setColor(self: *Self, color: Color) void {
            const count = self.getPixelCount();
            for (0..count) |i| {
                self.setPixel(@intCast(i), color);
            }
            self.refresh();
        }

        /// Set all pixels to black (off)
        pub fn clear(self: *Self) void {
            self.setColor(Color.black);
        }

        /// Refresh/flush to hardware (if driver supports it)
        pub fn refresh(self: *Self) void {
            if (@hasDecl(Driver, "refresh")) {
                self.driver.refresh();
            }
        }

        // ----- Brightness Control -----

        /// Set global brightness (0-255)
        pub fn setBrightness(self: *Self, brightness: u8) void {
            self.brightness = brightness;
        }

        /// Get current brightness
        pub fn getBrightness(self: Self) u8 {
            return self.brightness;
        }

        // ----- Enable Control -----

        /// Enable/disable LED output
        pub fn setEnabled(self: *Self, enabled: bool) void {
            self.enabled = enabled;
            if (!enabled) {
                // Write black to all pixels
                const count = self.driver.getPixelCount();
                for (0..count) |i| {
                    self.driver.setPixel(@intCast(i), Color.black);
                }
                self.refresh();
            }
        }

        /// Check if enabled
        pub fn isEnabled(self: Self) bool {
            return self.enabled;
        }

        // ----- Convenience Methods -----

        /// Fill a range of pixels with a color
        pub fn fillRange(self: *Self, start: u32, end: u32, color: Color) void {
            const count = self.getPixelCount();
            const actual_end = @min(end, count);
            for (start..actual_end) |i| {
                self.setPixel(@intCast(i), color);
            }
            self.refresh();
        }

        /// Set pixels from a color array
        pub fn setPixels(self: *Self, colors: []const Color) void {
            const count = self.getPixelCount();
            for (colors, 0..) |color, i| {
                if (i >= count) break;
                self.setPixel(@intCast(i), color);
            }
            self.refresh();
        }

        /// Apply gradient across all pixels
        pub fn setGradient(self: *Self, start: Color, to: Color) void {
            const count = self.getPixelCount();
            for (0..count) |i| {
                const t: u8 = if (count > 1)
                    @intCast((i * 255) / (count - 1))
                else
                    0;
                self.setPixel(@intCast(i), Color.lerp(start, to, t));
            }
            self.refresh();
        }

        /// Set rainbow pattern
        pub fn setRainbow(self: *Self, saturation: u8, value: u8) void {
            const count = self.getPixelCount();
            for (0..count) |i| {
                const hue: u8 = @intCast((i * 255) / count);
                self.setPixel(@intCast(i), Color.hsv(hue, saturation, value));
            }
            self.refresh();
        }
    };
}

// ============================================================================
// LED Strip Controller (Legacy - for animation support)
// ============================================================================

/// LED Strip Controller with animation support
///
/// Note: For new code, prefer using RgbLedStrip(spec) with a Driver.
/// This controller is maintained for backward compatibility and
/// for cases where you need animation state management.
pub fn LedStripController(comptime Config: type) type {
    const led_count = Config.led_count;
    const max_frames = Config.max_frames;

    return struct {
        const Self = @This();

        pub const Anim = Animation(max_frames, led_count);
        pub const KF = Keyframe(led_count);
        pub const FX = Effects(led_count);

        /// Function type for writing colors to hardware
        pub const WriteFn = *const fn (*const [led_count]Color) void;

        // Animation state
        animation: Anim = .{},
        current_frame: u8 = 0,
        prev_frame: u8 = 0,
        frame_start_ms: u64 = 0,
        playing: bool = false,

        // Overlay (temporary effect on top of animation)
        overlay: ?[led_count]Color = null,
        overlay_timeout_ms: u64 = 0,

        // Global controls
        brightness: u8 = 255,
        enabled: bool = true,
        paused: bool = false,

        // Hardware interface
        write_fn: WriteFn,

        // Cached output (for getCurrentColors)
        current_colors: [led_count]Color = [_]Color{Color.black} ** led_count,

        /// Initialize controller with hardware write function
        pub fn init(write_fn: WriteFn) Self {
            return .{ .write_fn = write_fn };
        }

        // ----- Animation Control -----

        /// Play an animation
        pub fn play(self: *Self, animation: Anim) void {
            self.animation = animation;
            self.current_frame = 0;
            self.prev_frame = 0;
            self.frame_start_ms = 0;
            self.playing = true;
        }

        /// Play comptime-defined keyframes
        pub fn playKeyframes(self: *Self, comptime keyframes: []const KF, loop: bool) void {
            self.play(Anim.init(keyframes, loop));
        }

        /// Stop animation (shows black)
        pub fn stop(self: *Self) void {
            self.playing = false;
            self.animation.clear();
        }

        /// Check if animation is playing
        pub fn isPlaying(self: Self) bool {
            return self.playing and !self.animation.isEmpty();
        }

        // ----- Overlay Control -----

        /// Set overlay colors (temporary effect)
        pub fn setOverlay(self: *Self, colors: [led_count]Color, duration_ms: u32, now_ms: u64) void {
            self.overlay = colors;
            self.overlay_timeout_ms = if (duration_ms == 0) 0 else now_ms + duration_ms;
        }

        /// Set solid color overlay
        pub fn setOverlaySolid(self: *Self, color: Color, duration_ms: u32, now_ms: u64) void {
            self.setOverlay([_]Color{color} ** led_count, duration_ms, now_ms);
        }

        /// Set overlay at specific LED index
        pub fn setOverlayAt(self: *Self, index: usize, color: Color, duration_ms: u32, now_ms: u64) void {
            if (self.overlay == null) {
                self.overlay = [_]Color{Color.black} ** led_count;
            }
            if (index < led_count) {
                self.overlay.?[index] = color;
            }
            self.overlay_timeout_ms = if (duration_ms == 0) 0 else now_ms + duration_ms;
        }

        /// Clear overlay
        pub fn clearOverlay(self: *Self) void {
            self.overlay = null;
        }

        /// Check if overlay is active
        pub fn hasOverlay(self: Self) bool {
            return self.overlay != null;
        }

        // ----- Global Controls -----

        /// Set brightness (0-255)
        pub fn setBrightness(self: *Self, brightness: u8) void {
            self.brightness = brightness;
        }

        /// Get current brightness
        pub fn getBrightness(self: Self) u8 {
            return self.brightness;
        }

        /// Enable/disable LED output
        pub fn setEnabled(self: *Self, enabled: bool) void {
            self.enabled = enabled;
        }

        /// Check if enabled
        pub fn isEnabled(self: Self) bool {
            return self.enabled;
        }

        /// Pause/resume animation (keeps current frame)
        pub fn setPaused(self: *Self, paused: bool) void {
            self.paused = paused;
        }

        /// Check if paused
        pub fn isPaused(self: Self) bool {
            return self.paused;
        }

        // ----- Main Update Loop -----

        /// Update animation state and write to hardware
        /// Call this periodically (e.g., every 10-50ms)
        pub fn tick(self: *Self, now_ms: u64) void {
            // Disabled: output black
            if (!self.enabled) {
                self.current_colors = [_]Color{Color.black} ** led_count;
                self.write_fn(&self.current_colors);
                return;
            }

            // Check overlay timeout
            if (self.overlay != null and self.overlay_timeout_ms > 0 and now_ms >= self.overlay_timeout_ms) {
                self.overlay = null;
            }

            // Determine output colors
            if (self.overlay) |ov| {
                // Overlay takes priority
                self.current_colors = ov;
            } else if (self.playing and !self.paused and !self.animation.isEmpty()) {
                // Animation frame with interpolation
                const frame = self.animation.frames[self.current_frame];
                const prev_colors = self.animation.frames[self.prev_frame].colors;

                // Initialize frame start time
                if (self.frame_start_ms == 0) {
                    self.frame_start_ms = now_ms;
                }

                // Calculate interpolation
                if (frame.easing != .none and frame.duration_ms != 0xFFFF and frame.duration_ms > 0) {
                    // Calculate progress (0-255)
                    const elapsed = now_ms -| self.frame_start_ms;
                    const progress: u8 = if (elapsed >= frame.duration_ms)
                        255
                    else
                        @intCast((elapsed * 255) / frame.duration_ms);

                    // Apply easing curve
                    const eased_t = frame.easing.apply(progress);

                    // Interpolate colors
                    for (0..led_count) |i| {
                        self.current_colors[i] = Color.lerp(prev_colors[i], frame.colors[i], eased_t);
                    }
                } else {
                    // No easing: direct assignment
                    self.current_colors = frame.colors;
                }

                // Check for frame advance
                if (frame.duration_ms != 0xFFFF and now_ms >= self.frame_start_ms + frame.duration_ms) {
                    self.advanceFrame();
                    self.frame_start_ms = now_ms;
                }
            } else {
                // Nothing playing: black
                self.current_colors = [_]Color{Color.black} ** led_count;
            }

            // Apply brightness
            var output = self.current_colors;
            if (self.brightness < 255) {
                for (&output) |*c| {
                    c.* = c.withBrightness(self.brightness);
                }
            }

            self.write_fn(&output);
        }

        /// Get current colors (before brightness adjustment)
        pub fn getCurrentColors(self: Self) [led_count]Color {
            return self.current_colors;
        }

        /// Get current frame index
        pub fn getCurrentFrame(self: Self) u8 {
            return self.current_frame;
        }

        // ----- Internal -----

        fn advanceFrame(self: *Self) void {
            self.prev_frame = self.current_frame;
            self.current_frame += 1;
            if (self.current_frame >= self.animation.frame_count) {
                if (self.animation.loop) {
                    self.current_frame = 0;
                } else {
                    // Stay on last frame, stop playing
                    self.current_frame = self.animation.frame_count -| 1;
                    self.playing = false;
                }
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Color basics" {
    const c = Color.rgb(100, 150, 200);
    try std.testing.expectEqual(@as(u8, 100), c.r);
    try std.testing.expectEqual(@as(u8, 150), c.g);
    try std.testing.expectEqual(@as(u8, 200), c.b);

    // Brightness
    const dimmed = c.withBrightness(128);
    try std.testing.expectEqual(@as(u8, 50), dimmed.r);

    // Lerp
    const mid = Color.lerp(Color.black, Color.white, 128);
    try std.testing.expect(mid.r > 120 and mid.r < 130);
}

test "Color HSV" {
    // Red at full saturation and value
    const red = Color.hsv(0, 255, 255);
    try std.testing.expectEqual(@as(u8, 255), red.r);
    try std.testing.expectEqual(@as(u8, 0), red.g);

    // Green (hue ~85)
    const green = Color.hsv(85, 255, 255);
    try std.testing.expect(green.g > green.r);
    try std.testing.expect(green.g > green.b);
}

test "Keyframe and Animation" {
    const KF = Keyframe(4);
    const Anim = Animation(8, 4);

    // Create keyframe
    const kf = KF.solid(Color.red, 100);
    try std.testing.expectEqual(Color.red, kf.colors[0]);
    try std.testing.expectEqual(@as(u16, 100), kf.duration_ms);

    // Create animation at runtime
    var anim = Anim{};
    try std.testing.expect(anim.isEmpty());

    _ = anim.addSolid(Color.red, 100);
    _ = anim.addSolid(Color.blue, 200);
    try std.testing.expectEqual(@as(u8, 2), anim.frame_count);
    try std.testing.expect(!anim.isEmpty());
}

test "Effects generator" {
    const FX = Effects(4);

    // Solid
    const solid = FX.solid(Color.red);
    try std.testing.expectEqual(@as(usize, 1), solid.len);
    try std.testing.expectEqual(Color.red, solid[0].colors[0]);

    // Breathing
    const breath = FX.breathing(Color.green, 500, 300);
    try std.testing.expectEqual(@as(usize, 2), breath.len);
    try std.testing.expectEqual(@as(u16, 500), breath[0].duration_ms);
    try std.testing.expectEqual(@as(u16, 300), breath[1].duration_ms);

    // Gradient
    const grad = FX.gradient(Color.black, Color.white);
    try std.testing.expectEqual(@as(u8, 0), grad[0].r);
    try std.testing.expectEqual(@as(u8, 255), grad[3].r);
}

var test_output: [4]Color = undefined;

fn testWriteFn(colors: *const [4]Color) void {
    test_output = colors.*;
}

test "LedStripController basics" {
    const Config = struct {
        pub const led_count = 4;
        pub const max_frames = 8;
    };

    const Controller = LedStripController(Config);

    var ctrl = Controller.init(&testWriteFn);

    // Initial state
    try std.testing.expect(!ctrl.isPlaying());
    try std.testing.expectEqual(@as(u8, 255), ctrl.getBrightness());

    // Play solid red
    ctrl.playKeyframes(&Controller.FX.solid(Color.red), false);
    try std.testing.expect(ctrl.isPlaying());

    // Tick should write red
    ctrl.tick(0);
    try std.testing.expectEqual(Color.red, test_output[0]);

    // Set overlay
    ctrl.setOverlaySolid(Color.blue, 100, 0);
    ctrl.tick(50);
    try std.testing.expectEqual(Color.blue, test_output[0]);

    // Overlay expires
    ctrl.tick(150);
    try std.testing.expectEqual(Color.red, test_output[0]);
}

test "RgbLedStrip with mock driver" {
    // Mock driver implementation
    const MockDriver = struct {
        pixels: [8]Color = [_]Color{Color.black} ** 8,
        refresh_count: u32 = 0,

        pub fn setPixel(self: *@This(), index: u32, color: Color) void {
            if (index < self.pixels.len) {
                self.pixels[index] = color;
            }
        }

        pub fn getPixelCount(_: *@This()) u32 {
            return 8;
        }

        pub fn refresh(self: *@This()) void {
            self.refresh_count += 1;
        }
    };

    // Define spec
    const led_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "led.test" };
    };

    const TestLedStrip = from(led_spec);

    var driver = MockDriver{};
    var led = TestLedStrip.init(&driver);

    // Test metadata
    try std.testing.expectEqualStrings("led.test", TestLedStrip.meta.id);

    // Test pixel count
    try std.testing.expectEqual(@as(u32, 8), led.getPixelCount());

    // Test setColor
    led.setColor(Color.red);
    try std.testing.expectEqual(Color.red, driver.pixels[0]);
    try std.testing.expectEqual(Color.red, driver.pixels[7]);
    try std.testing.expect(driver.refresh_count > 0);

    // Test brightness
    led.setBrightness(128);
    led.setColor(Color.white);
    // With 50% brightness, white should become ~128,128,128
    try std.testing.expect(driver.pixels[0].r < 200);
    try std.testing.expect(driver.pixels[0].r > 100);

    // Test clear
    led.setBrightness(255);
    led.clear();
    try std.testing.expectEqual(Color.black, driver.pixels[0]);

    // Test gradient
    led.setGradient(Color.black, Color.white);
    try std.testing.expectEqual(@as(u8, 0), driver.pixels[0].r);
    try std.testing.expectEqual(@as(u8, 255), driver.pixels[7].r);

    // Test enable/disable
    led.setEnabled(false);
    try std.testing.expect(!led.isEnabled());
    led.setColor(Color.red); // Should be ignored
    try std.testing.expectEqual(Color.black, driver.pixels[0]); // Still black
}
