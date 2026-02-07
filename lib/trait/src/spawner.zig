//! Spawner Trait — Task/thread spawning contract
//!
//! Validates that a Runtime type can spawn OS tasks or threads.
//! Used by WaitGroup.go() to spawn tasks in a platform-independent way.
//!
//! ## Contract
//!
//! ```zig
//! const Runtime = struct {
//!     pub const Options = struct {
//!         stack_size: u32 = 8192,
//!         priority: u8 = 16,
//!         core: i8 = -1,
//!     };
//!     pub fn spawn(name: [:0]const u8, func: TaskFn, ctx: ?*anyopaque, opts: Options) !void;
//! };
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // In cross-platform package:
//! pub fn WaitGroup(comptime Rt: type) type {
//!     comptime spawner.from(Rt);  // validate
//!     return struct {
//!         pub fn go(self: *Self, name: [:0]const u8, func: TaskFn, ctx: ?*anyopaque, opts: Rt.Options) !void {
//!             self.add(1);
//!             try Rt.spawn(name, wrappedFn, wrappedCtx, opts);
//!         }
//!     };
//! }
//! ```

/// Task function signature
pub const TaskFn = *const fn (?*anyopaque) void;

/// Validate that Impl is a valid Spawner
///
/// Required:
/// - `Options` type (spawn configuration)
/// - `spawn(name, func, ctx, opts) !void`
pub fn from(comptime Impl: type) void {
    comptime {
        if (!@hasDecl(Impl, "Options")) @compileError("Spawner missing Options type");
        if (!@hasDecl(Impl, "spawn")) @compileError("Spawner missing spawn() function");
    }
}
