//! Timer Trait — Timer service contract
//!
//! Validates that a type provides timer scheduling capabilities.
//! Used by KCP Mux for periodic update scheduling.
//!
//! ## Contract
//!
//! ```zig
//! const TimerService = struct {
//!     pub fn schedule(self: *TimerService, delay_ms: u32, callback: Callback, ctx: ?*anyopaque) TimerHandle;
//!     pub fn cancel(self: *TimerService, handle: TimerHandle) void;
//! };
//! ```
//!
//! Callback reuses `spawner.TaskFn` — same signature: `*const fn (?*anyopaque) void`.
//!
//! ## Usage
//!
//! ```zig
//! pub fn Mux(comptime Rt: type, comptime TimerSvc: type) type {
//!     comptime timer.from(TimerSvc);  // validate
//!     return struct {
//!         timer_service: *TimerSvc,
//!         // ...
//!     };
//! }
//! ```

const spawner = @import("spawner.zig");

/// Timer callback — reuses spawner.TaskFn: `*const fn (?*anyopaque) void`
pub const Callback = spawner.TaskFn;

/// Handle to a scheduled timer, used for cancellation.
pub const TimerHandle = struct {
    id: u64,

    /// A null handle representing no timer.
    pub const null_handle: TimerHandle = .{ .id = 0 };

    /// Check if this is a valid (non-null) handle.
    pub fn isValid(self: TimerHandle) bool {
        return self.id != 0;
    }
};

/// Validate that Impl is a valid TimerService type
///
/// Required:
/// - `schedule(*Impl, u32, Callback, ?*anyopaque) TimerHandle`
/// - `cancel(*Impl, TimerHandle) void`
pub fn from(comptime Impl: type) void {
    comptime {
        if (!@hasDecl(Impl, "schedule")) @compileError("TimerService missing schedule() function");
        if (!@hasDecl(Impl, "cancel")) @compileError("TimerService missing cancel() function");
    }
}

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "TimerHandle validity" {
    try std.testing.expect(!TimerHandle.null_handle.isValid());
    const valid = TimerHandle{ .id = 1 };
    try std.testing.expect(valid.isValid());
}
