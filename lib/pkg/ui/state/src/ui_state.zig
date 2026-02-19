//! UI Rendering — Framebuffer + Fonts + Dirty Tracking + Compositor
//!
//! Rendering primitives for embedded small-screen devices.
//! For state management (Store), use lib/pkg/flux.
//!
//! ```zig
//! const ui = @import("ui_state");
//! const fb = ui.Framebuffer(240, 240, .rgb565).init(0);
//! fb.fillRect(10, 10, 50, 50, 0xF800);
//! ```

// Rendering
pub const Framebuffer = @import("framebuffer.zig").Framebuffer;
pub const ColorFormat = @import("framebuffer.zig").ColorFormat;

// Font
pub const BitmapFont = @import("font.zig").BitmapFont;
pub const asciiLookup = @import("font.zig").asciiLookup;
pub const decodeUtf8 = @import("font.zig").decodeUtf8;
pub const TtfFont = @import("ttf_font.zig").TtfFont;

// Image
pub const Image = @import("image.zig").Image;

// Dirty tracking
pub const Rect = @import("dirty.zig").Rect;
pub const DirtyTracker = @import("dirty.zig").DirtyTracker;

// Animation
pub const AnimPlayer = @import("anim.zig").AnimPlayer;
pub const AnimFrame = @import("anim.zig").AnimFrame;
pub const blitAnimFrame = @import("anim.zig").blitAnimFrame;

// Scene compositor (component-based partial redraw)
pub const Compositor = @import("scene.zig").Compositor;
pub const Region = @import("scene.zig").Region;
pub const SceneRenderer = @import("scene.zig").SceneRenderer;

// ============================================================================
// Tests — pull in all sub-module tests
// ============================================================================

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("dirty.zig");
    _ = @import("framebuffer.zig");
    _ = @import("font.zig");
    _ = @import("image.zig");
    _ = @import("anim.zig");
    _ = @import("scene.zig");
}
