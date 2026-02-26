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
//!         pub fn init() !Self;
//!         pub fn deinit(self: *Self) void;
//!         pub fn addRecv(self: *Self, channel: anytype) error{ TooMany }!usize;
//!         pub fn addTimeout(self: *Self, timeout_ms: u32) error{ TooMany }!usize;
//!         pub fn wait(self: *Self, timeout_ms: ?u32) error{ Empty }!usize;
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
//! const timeout_idx = try sel.addTimeout(100);  // 100ms timeout
//!
//! const idx = sel.wait(null) catch |err| switch (err) {
//!     error.Empty => return,  // no sources added
//! };
//!
//! switch (idx) {
//!     0 => { const v = ch1.recv(); },
//!     1 => { const v = ch2.recv(); },
//!     timeout_idx => { /* timeout */ },
//! }
//! ```

/// Validate that Impl is a valid Selector type for max_sources.
///
/// Required methods:
/// - `init() -> !Self`
/// - `deinit(*Self) -> void`
/// - `addRecv(*Self, anytype) error{TooMany}!usize`
/// - `addTimeout(*Self, u32) error{TooMany}!usize`
/// - `wait(*Self, ?u32) error{Empty}!usize`
/// - `reset(*Self) -> void`
pub fn validate(comptime Impl: type) void {
    comptime {
        const Self = Impl;

        // Check init/deinit
        _ = @as(*const fn () anyerror!Self, &Impl.init);
        _ = @as(*const fn (*Self) void, &Impl.deinit);

        // Check add operations
        if (!@hasDecl(Impl, "addRecv")) @compileError("Selector missing addRecv method");
        if (!@hasDecl(Impl, "addTimeout")) @compileError("Selector missing addTimeout method");
        _ = @as(*const fn (*Self, u32) anyerror!usize, &Impl.addTimeout);

        // Check wait
        _ = @as(*const fn (*Self, ?u32) anyerror!usize, &Impl.wait);

        // Check reset
        _ = @as(*const fn (*Self) void, &Impl.reset);
    }
}

/// Error type for Selector when no sources are registered
pub const Empty = error{Empty};
