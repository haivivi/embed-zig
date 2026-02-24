//! Channel Trait — Go-style typed communication channel interface
//!
//! Defines the contract for platform-specific Channel implementations.
//! Channel is a bounded, thread-safe FIFO queue with Go `chan` semantics.
//!
//! ## Contract
//!
//! A Channel implementation must provide:
//!
//! ```zig
//! pub fn Channel(comptime T: type, comptime capacity: usize) type {
//!     return struct {
//!         pub fn init() Self;
//!         pub fn deinit(self: *Self) void;
//!         pub fn send(self: *Self, item: T) error{Closed}!void;
//!         pub fn trySend(self: *Self, item: T) error{ Closed, Full }!void;
//!         pub fn recv(self: *Self) ?T;
//!         pub fn tryRecv(self: *Self) ?T;
//!         pub fn close(self: *Self) void;
//!         pub fn isClosed(self: *Self) bool;
//!         pub fn count(self: *Self) usize;
//!         pub fn isEmpty(self: *Self) bool;
//!     };
//! }
//! ```
//!
//! ## Platform Implementations
//!
//! - **std (macOS/Linux)**: Mutex + buffer + pipe/eventfd for select support
//! - **ESP32/FreeRTOS**: Direct xQueue (native select via xQueueSet)
//!
//! ## Usage
//!
//! ```zig
//! // In app code, use platform-provided Channel:
//! const platform = @import("platform");
//! const Ch = platform.Channel(u32, 16);
//!
//! var ch = Ch.init();
//! defer ch.deinit();
//!
//! try ch.send(42);
//! const item = ch.recv();  // 42
//! ```

/// Validate that Impl is a valid Channel type for element type T.
///
/// Required methods:
/// - `init() -> Self`
/// - `deinit(*Self) -> void`
/// - `send(*Self, T) error{Closed}!void`
/// - `trySend(*Self, T) error{ Closed, Full }!void`
/// - `recv(*Self) ?T`
/// - `tryRecv(*Self) ?T`
/// - `close(*Self) -> void`
/// - `isClosed(*Self) -> bool`
/// - `count(*Self) -> usize`
/// - `isEmpty(*Self) -> bool`
pub fn validate(comptime T: type, comptime Impl: type) void {
    comptime {
        const Self = Impl;

        // Check init/deinit
        _ = @as(*const fn () Self, &Impl.init);
        _ = @as(*const fn (*Self) void, &Impl.deinit);

        // Check send operations
        _ = @as(*const fn (*Self, T) error{Closed}!void, &Impl.send);
        _ = @as(*const fn (*Self, T) error{ Closed, Full }!void, &Impl.trySend);

        // Check recv operations
        _ = @as(*const fn (*Self) ?T, &Impl.recv);
        _ = @as(*const fn (*Self) ?T, &Impl.tryRecv);

        // Check control operations
        _ = @as(*const fn (*Self) void, &Impl.close);
        _ = @as(*const fn (*Self) bool, &Impl.isClosed);

        // Check status operations
        _ = @as(*const fn (*Self) usize, &Impl.count);
        _ = @as(*const fn (*Self) bool, &Impl.isEmpty);
    }
}

/// Error types used by Channel operations
pub const Closed = error{Closed};
pub const Full = error{Full};
