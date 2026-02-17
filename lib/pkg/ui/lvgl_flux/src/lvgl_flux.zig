//! LVGL + Flux — Retained-mode rendering driven by Redux state
//!
//! Bridges the Flux state management pattern with LVGL's widget system.
//! State changes flow through a reducer; the sync function maps state
//! to LVGL widget properties. LVGL internally tracks which widgets
//! actually changed and only redraws those areas.
//!
//! Architecture:
//!   Event → Flux Store → reduce() → new State
//!   State → View.sync(state) → updates LVGL widget properties
//!   LVGL timer_handler() → partial flush of changed areas only
//!
//! ## Usage
//!
//! ```zig
//! const flux = @import("flux");
//! const lvgl_flux = @import("lvgl_flux");
//!
//! // Define app with state, events, reducer, and LVGL view
//! const MyApp = struct {
//!     pub const State = struct { title: []const u8 = "Hello", count: u32 = 0 };
//!     pub const Event = union(enum) { increment, set_title: []const u8 };
//!
//!     pub fn reduce(s: *State, e: Event) void {
//!         switch (e) {
//!             .increment => s.count += 1,
//!             .set_title => |t| s.title = t,
//!         }
//!     }
//! };
//!
//! // Create view with LVGL widgets
//! var view = lvgl_flux.View(MyApp).init(ctx.screen());
//! var app = flux.AppStateManager(MyApp).init(.{ .fps = 30 });
//!
//! // In the event loop:
//! app.dispatch(.increment);
//! if (app.shouldRender(now_ms)) {
//!     view.sync(app.getState());   // only updates changed properties
//!     app.commitFrame(now_ms);
//! }
//! ctx.tick(ms);
//! _ = ctx.handler();  // LVGL flushes only dirty widget areas
//! ```

const std = @import("std");

/// Render statistics for benchmarking and monitoring.
pub const RenderStats = struct {
    /// Number of sync() calls (frames rendered)
    frame_count: u64 = 0,
    /// Number of widget property updates across all sync() calls
    property_updates: u64 = 0,
    /// Number of sync() calls that were skipped (no state change)
    skipped_frames: u64 = 0,

    pub fn reset(self: *RenderStats) void {
        self.* = .{};
    }

    /// Average property updates per frame
    pub fn avgUpdatesPerFrame(self: *const RenderStats) u64 {
        return if (self.frame_count > 0)
            self.property_updates / self.frame_count
        else
            0;
    }
};

/// ViewBinding describes how a single piece of state maps to an LVGL widget.
///
/// Apps define an array of ViewBindings to declaratively describe the
/// state → widget mapping. The sync engine iterates bindings and only
/// calls LVGL APIs when the relevant state field actually changed.
///
/// This is the core abstraction that enables LVGL's partial refresh:
/// unchanged bindings → no LVGL call → no widget invalidation → no redraw.
pub fn ViewBinding(comptime State: type) type {
    return struct {
        /// Sync function: reads state, updates LVGL widget if needed.
        /// Returns true if a widget property was updated.
        sync_fn: *const fn (state: *const State, prev: *const State) bool,
    };
}

/// SyncEngine drives LVGL widget updates from Flux state changes.
///
/// It holds an array of ViewBindings and iterates them on each sync() call,
/// comparing current vs previous state to determine what changed.
///
/// Usage:
///   var engine = SyncEngine(MyApp.State, &bindings).init();
///   // In render loop:
///   engine.sync(store.getState(), store.getPrev());
pub fn SyncEngine(comptime State: type, comptime bindings: []const ViewBinding(State)) type {
    return struct {
        const Self = @This();

        stats: RenderStats = .{},

        pub fn init() Self {
            return .{};
        }

        /// Sync all bindings: compare current vs previous state,
        /// update LVGL widgets only where state actually changed.
        ///
        /// Call this when Flux store reports isDirty(). After sync,
        /// call lv_timer_handler() to let LVGL flush only the
        /// invalidated widget areas.
        pub fn sync(self: *Self, state: *const State, prev: *const State) void {
            var updates: u64 = 0;
            inline for (bindings) |binding| {
                if (binding.sync_fn(state, prev)) {
                    updates += 1;
                }
            }
            self.stats.frame_count += 1;
            self.stats.property_updates += updates;
            if (updates == 0) {
                self.stats.skipped_frames += 1;
            }
        }

        /// Get render statistics.
        pub fn getStats(self: *const Self) RenderStats {
            return self.stats;
        }

        /// Number of bindings in this engine.
        pub fn bindingCount() usize {
            return bindings.len;
        }
    };
}

/// Helper: compare a field of two state instances.
/// Returns true if the field changed (i.e., needs LVGL update).
pub fn fieldChanged(comptime State: type, comptime field: []const u8, current: *const State, prev: *const State) bool {
    return @field(current, field) != @field(prev, field);
}

// ============================================================================
// Tests
// ============================================================================

test "SyncEngine: basic sync with no changes" {
    const State = struct {
        count: u32 = 0,
        page: u8 = 0,
    };

    const bindings = [_]ViewBinding(State){
        .{ .sync_fn = struct {
            fn f(s: *const State, p: *const State) bool {
                _ = s;
                _ = p;
                return false; // nothing changed
            }
        }.f },
    };

    var engine = SyncEngine(State, &bindings).init();
    const state = State{};
    engine.sync(&state, &state);

    try std.testing.expectEqual(@as(u64, 1), engine.stats.frame_count);
    try std.testing.expectEqual(@as(u64, 0), engine.stats.property_updates);
    try std.testing.expectEqual(@as(u64, 1), engine.stats.skipped_frames);
}

test "SyncEngine: detects property updates" {
    const State = struct {
        count: u32 = 0,
        label: u8 = 0,
    };

    const bindings = [_]ViewBinding(State){
        .{ .sync_fn = struct {
            fn f(s: *const State, p: *const State) bool {
                return s.count != p.count;
            }
        }.f },
        .{ .sync_fn = struct {
            fn f(s: *const State, p: *const State) bool {
                return s.label != p.label;
            }
        }.f },
    };

    var engine = SyncEngine(State, &bindings).init();

    // Frame 1: count changed
    const s1 = State{ .count = 1, .label = 0 };
    const s0 = State{ .count = 0, .label = 0 };
    engine.sync(&s1, &s0);

    try std.testing.expectEqual(@as(u64, 1), engine.stats.frame_count);
    try std.testing.expectEqual(@as(u64, 1), engine.stats.property_updates);

    // Frame 2: both changed
    const s2 = State{ .count = 2, .label = 1 };
    engine.sync(&s2, &s1);

    try std.testing.expectEqual(@as(u64, 2), engine.stats.frame_count);
    try std.testing.expectEqual(@as(u64, 3), engine.stats.property_updates); // 1 + 2
}

test "SyncEngine: stats tracking" {
    const State = struct { x: u32 = 0 };

    const bindings = [_]ViewBinding(State){
        .{ .sync_fn = struct {
            fn f(s: *const State, p: *const State) bool {
                return s.x != p.x;
            }
        }.f },
    };

    var engine = SyncEngine(State, &bindings).init();

    // 5 frames, 3 with changes
    const s0 = State{ .x = 0 };
    const s1 = State{ .x = 1 };
    const s2 = State{ .x = 2 };

    engine.sync(&s1, &s0); // changed
    engine.sync(&s1, &s1); // no change
    engine.sync(&s2, &s1); // changed
    engine.sync(&s2, &s2); // no change
    engine.sync(&s0, &s2); // changed

    try std.testing.expectEqual(@as(u64, 5), engine.stats.frame_count);
    try std.testing.expectEqual(@as(u64, 3), engine.stats.property_updates);
    try std.testing.expectEqual(@as(u64, 2), engine.stats.skipped_frames);
    try std.testing.expectEqual(@as(u64, 0), engine.getStats().avgUpdatesPerFrame());
    // 3 updates / 5 frames = 0 (integer division)
}

test "fieldChanged helper" {
    const State = struct {
        score: u32 = 0,
        page: u8 = 0,
    };

    const s1 = State{ .score = 100, .page = 1 };
    const s2 = State{ .score = 100, .page = 2 };

    try std.testing.expect(!fieldChanged(State, "score", &s1, &s2));
    try std.testing.expect(fieldChanged(State, "page", &s1, &s2));
}

test "SyncEngine: bindingCount" {
    const State = struct { x: u32 = 0 };
    const bindings = [_]ViewBinding(State){
        .{ .sync_fn = struct {
            fn f(_: *const State, _: *const State) bool {
                return false;
            }
        }.f },
        .{ .sync_fn = struct {
            fn f(_: *const State, _: *const State) bool {
                return false;
            }
        }.f },
        .{ .sync_fn = struct {
            fn f(_: *const State, _: *const State) bool {
                return false;
            }
        }.f },
    };

    try std.testing.expectEqual(@as(usize, 3), SyncEngine(State, &bindings).bindingCount());
}

test "RenderStats: reset" {
    var stats = RenderStats{
        .frame_count = 100,
        .property_updates = 50,
        .skipped_frames = 20,
    };
    stats.reset();
    try std.testing.expectEqual(@as(u64, 0), stats.frame_count);
    try std.testing.expectEqual(@as(u64, 0), stats.property_updates);
    try std.testing.expectEqual(@as(u64, 0), stats.skipped_frames);
}

test "RenderStats: avgUpdatesPerFrame" {
    const stats = RenderStats{
        .frame_count = 10,
        .property_updates = 25,
        .skipped_frames = 3,
    };
    try std.testing.expectEqual(@as(u64, 2), stats.avgUpdatesPerFrame()); // 25/10 = 2

    const empty = RenderStats{};
    try std.testing.expectEqual(@as(u64, 0), empty.avgUpdatesPerFrame());
}
