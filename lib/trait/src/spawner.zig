//! Spawner Trait — Thread spawning and management contract
//!
//! Defines the interface for creating and managing joinable threads.
//! Used by WaitGroup, zgrnet, and other async primitives.
//!
//! ## Thread Contract
//!
//! ```zig
//! const Runtime = struct {
//!     pub const Thread = struct {
//!         pub const SpawnConfig = struct {
//!             stack_size: usize = 8192,
//!         };
//!
//!         pub fn spawn(config: SpawnConfig, comptime func: anytype, args: anytype) !Thread;
//!         pub fn join(self: Thread) void;
//!         pub fn detach(self: Thread) void;
//!     };
//! };
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // Joinable thread
//! const thread = try Rt.Thread.spawn(.{}, worker, .{ctx});
//! thread.join();
//!
//! // Fire-and-forget
//! const thread = try Rt.Thread.spawn(.{}, worker, .{ctx});
//! thread.detach();
//! ```

const std = @import("std");

/// Standard task function signature for spawned work items.
pub const TaskFn = *const fn (?*anyopaque) void;
/// Validate that Impl provides Thread
///
/// Required:
/// - `Thread` type with `spawn()`, `join()`, `detach()`
pub fn from(comptime Impl: type) void {
    comptime {
        // Validate Thread type
        if (!@hasDecl(Impl, "Thread")) @compileError("Spawner missing Thread type");

        const ThreadType = Impl.Thread;
        if (!@hasDecl(ThreadType, "spawn")) @compileError("Thread missing spawn() method");
        if (!@hasDecl(ThreadType, "join")) @compileError("Thread missing join() method");
        if (!@hasDecl(ThreadType, "detach")) @compileError("Thread missing detach() method");

        if (!@hasDecl(ThreadType, "SpawnConfig")) {
            @compileError("Thread missing SpawnConfig type");
        }

        const spawn_info = @typeInfo(@TypeOf(ThreadType.spawn));
        if (spawn_info != .@"fn") @compileError("Thread.spawn must be a function");
        const spawn_fn = spawn_info.@"fn";
        if (spawn_fn.params.len != 3) {
            @compileError("Thread.spawn must have signature spawn(config, comptime func, args)");
        }
        if (spawn_fn.params[0].type != ThreadType.SpawnConfig) {
            @compileError("Thread.spawn first parameter must be SpawnConfig");
        }
        if (spawn_fn.return_type == null) {
            @compileError("Thread.spawn must return error union of Thread");
        }
        const spawn_ret = @typeInfo(spawn_fn.return_type.?);
        if (spawn_ret != .error_union or spawn_ret.error_union.payload != ThreadType) {
            @compileError("Thread.spawn must return !Thread");
        }

        _ = @as(*const fn (ThreadType) void, &ThreadType.join);
        _ = @as(*const fn (ThreadType) void, &ThreadType.detach);
    }
}
