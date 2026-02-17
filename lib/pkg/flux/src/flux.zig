//! Flux — Unidirectional data flow framework
//!
//! Event → Reducer → State → Render
//!
//! Core components:
//!   Store: Redux-style state container (dispatch, reduce, commitFrame)
//!   AppStateManager: Event dispatch + frame-rate controlled render scheduling
//!
//! Usage:
//!   const flux = @import("flux");
//!
//!   var app = flux.AppStateManager(MyApp).init(.{ .fps = 30 });
//!   app.dispatch(event);
//!   if (app.shouldRender(now_ms)) {
//!       MyApp.render(&fb, app.getState(), &resources);
//!       app.commitFrame(now_ms);
//!   }

pub const Store = @import("store.zig").Store;
pub const AppStateManager = @import("app_state_manager.zig").AppStateManager;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("store.zig");
    _ = @import("app_state_manager.zig");
}
