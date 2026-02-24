//! Selector Trait — Multi-channel wait interface
//!
//! Defines the contract for platform-specific Selector implementations.
//! A Selector allows waiting on multiple channels simultaneously, similar to
//! Go's `select` or Rust's `tokio::select!`.
//!
//! ## Contract
//!
//! A Selector implementation must provide:
//!
//! ```zig
//! pub fn Selector(comptime max_sources: usize) type {
//!     return struct {
//!         pub fn init() Self;
//!         pub fn deinit(self: *Self) void;
//!         pub fn addRecv(self: *Self, channel: anytype) error{ TooMany }!void;
//!         pub fn addTimeout(self: *Self, timeout_ms: u32) error{ TooMany }!void;
//!         pub fn wait(self: *Self) error{ Empty }!usize;
//!         pub fn reset(self: *Self) void;
//!     };
//! }
//! ```
//!
//! ## Platform Implementations
//!
//! - **std (macOS)**: kqueue + pipe fd
//! - **std (Linux)**: epoll + eventfd
//! - **ESP32/FreeRTOS**: xQueueSet
//!
//! ## Usage
//!
//! ```zig
//! const platform = @import("platform");
//! const Selector = platform.Selector(3);
//!
//! var sel = Selector.init();
//! defer sel.deinit();
//!
//! try sel.addRecv(&ch1);
//! try sel.addRecv(&ch2);
//! try sel.addTimeout(100);  // 100ms timeout
//!
//! const idx = sel.wait() catch |err| switch (err) {
//!     error.Empty => return,  // no sources added
//! };
//!
//! switch (idx) {
//!     0 => { const v = ch1.recv(); },
//!     1 => { const v = ch2.recv(); },
//!     2 => { /* timeout */ },
//! }
//! ```

/// Validate that Impl is a valid Selector type for max_sources.
///
/// Required methods:
/// - `init() -> Self`
/// - `deinit(*Self) -> void`
/// - `addRecv(*Self, anytype) error{TooMany}!void`
/// - `addTimeout(*Self, u32) error{TooMany}!void`
/// - `wait(*Self) error{Empty}!usize`
/// - `reset(*Self) -> void`
pub fn validate(comptime Impl: type) void {
    comptime {
        const Self = Impl;

        // Check init/deinit
        _ = @as(*const fn () Self, &Impl.init);
        _ = @as(*const fn (*Self) void, &Impl.deinit);

        // Check add operations
        if (!@hasDecl(Impl, "addRecv")) @compileError("Selector missing addRecv method");
        if (!@hasDecl(Impl, "addTimeout")) @compileError("Selector missing addTimeout method");

        // Check wait
        _ = @as(*const fn (*Self) error{Empty}!usize, &Impl.wait);

        // Check reset
        _ = @as(*const fn (*Self) void, &Impl.reset);
    }
}

/// Error type for Selector when no sources are registered
pub const Empty = error{Empty};
