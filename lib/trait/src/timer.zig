//! Timer Trait — Timer service contract
//!
//! Validates that a type provides timer scheduling capabilities.
//! Used by KCP Mux for periodic update scheduling.
//!
//! ## Contract
//!
//! ```zig
//! const TimerService = struct {
//!     pub fn schedule(self: *TimerService, delay_ms: u32, task: Task) TimerHandle;
//!     pub fn cancel(self: *TimerService, handle: TimerHandle) void;
//! };
//! ```
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

const task_mod = @import("task.zig");
pub const Task = task_mod.Task;
pub const TimerHandle = task_mod.TimerHandle;

/// Validate that Impl is a valid TimerService type
///
/// Required:
/// - `schedule(*Impl, u32, Task) TimerHandle`
/// - `cancel(*Impl, TimerHandle) void`
pub fn from(comptime Impl: type) void {
    comptime {
        if (!@hasDecl(Impl, "schedule")) @compileError("TimerService missing schedule() function");
        if (!@hasDecl(Impl, "cancel")) @compileError("TimerService missing cancel() function");
    }
}
