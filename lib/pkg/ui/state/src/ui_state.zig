//! UI State — Redux + Framebuffer UI Framework
//!
//! Lightweight UI framework for embedded small-screen devices.
//!
//! Core principles:
//! - Redux single-direction data flow (Event → Reduce → State → Render)
//! - Pure framebuffer rendering, no LVGL dependency
//! - No built-in widget library — apps define their own pages and components
//! - Single-thread, lock-free; external threads communicate via event queue
//!
//! ## Architecture
//!
//! ```
//! External threads (WiFi, BLE, Audio...)
//!   │
//!   └── push Event to Channel ──┐
//!                                │
//! Board hardware events ─────────┤
//!                                │
//!                                ▼
//!                     ┌──────────────────┐
//!                     │   UI Thread      │
//!                     │                  │
//!                     │  event = recv()  │
//!                     │  store.dispatch(event)
//!                     │                  │
//!                     │  if dirty:       │
//!                     │    render(state, prev, fb)
//!                     │    flush dirty rects to LCD
//!                     │    store.commitFrame()
//!                     │                  │
//!                     │  sleep(16ms)     │
//!                     └──────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const ui = @import("ui_state");
//!
//! const GameState = struct { score: u32 = 0 };
//! const GameEvent = union(enum) { tick, score_up };
//!
//! fn reduce(state: *GameState, event: GameEvent) void {
//!     switch (event) {
//!         .score_up => state.score += 1,
//!         .tick => {},
//!     }
//! }
//!
//! var store = ui.Store(GameState, GameEvent).init(.{}, reduce);
//! var fb = ui.Framebuffer(240, 240, .rgb565).init(0);
//! ```

// Core
pub const Store = @import("store.zig").Store;

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
    _ = @import("store.zig");
    _ = @import("dirty.zig");
    _ = @import("framebuffer.zig");
    _ = @import("font.zig");
    _ = @import("image.zig");
    _ = @import("anim.zig");
    _ = @import("scene.zig");
}
