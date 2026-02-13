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
//!     
//!     pub fn getCpuCount() !usize;
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
//!
//! // Get CPU count
//! const num_workers = try Rt.getCpuCount();
//! ```

const std = @import("std");

/// Validate that Impl provides Thread and getCpuCount
///
/// Required:
/// - `Thread` type with `spawn()`, `join()`, `detach()`
/// - `getCpuCount() !usize`
pub fn from(comptime Impl: type) void {
    comptime {
        // Validate Thread type
        if (!@hasDecl(Impl, "Thread")) @compileError("Spawner missing Thread type");
        
        const ThreadType = Impl.Thread;
        if (!@hasDecl(ThreadType, "spawn")) @compileError("Thread missing spawn() method");
        if (!@hasDecl(ThreadType, "join")) @compileError("Thread missing join() method");
        if (!@hasDecl(ThreadType, "detach")) @compileError("Thread missing detach() method");
        
        // Validate getCpuCount
        if (!@hasDecl(Impl, "getCpuCount")) @compileError("Spawner missing getCpuCount() function");
        
        // Validate return type (allow any error set)
        const getCpuCountFn = @typeInfo(@TypeOf(Impl.getCpuCount));
        if (getCpuCountFn != .@"fn") @compileError("getCpuCount must be a function");
        
        const return_type = @typeInfo(getCpuCountFn.@"fn".return_type.?);
        if (return_type != .error_union) @compileError("getCpuCount() must return error union");
        if (return_type.error_union.payload != usize) {
            @compileError("getCpuCount() must return !usize");
        }
    }
}
