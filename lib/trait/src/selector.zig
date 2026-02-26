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
//! pub fn Selector(comptime max_sources: usize, comptime max_events: usize) type {
//!     return struct {
//!         pub fn init() !Self;
//!         pub fn deinit(*Self) -> void;
//!         pub fn addRecv(*Self, anytype) anyerror!usize;
//!         pub fn addTimeout(*Self, u32) error{TooMany}!usize;
//!         pub fn wait(*Self, ?u32) anyerror!usize;
//!         pub fn reset(*Self) -> void;
//!     };
//! }
//! ```
//!
//! Typical `addRecv` errors:
//! - `error.TooMany`
//! - `error.QueueSetCapacityExceeded`
//! - `error.QueueAddFailed`
//! - `error.RollbackFailed`
//!
//! Typical `wait` errors:
//! - `error.Empty`
//! - `error.PollWaitFailed`
//! - `error.Interrupted` (platform-dependent)
//!
//! ## Parameters
//!
//! - `max_sources`: Maximum number of channels that can be registered
//! - `max_events`: Backend-specific event budget used by selector internals.
//!   - **FreeRTOS (ESP/BK)**: must equal the sum of all registered channels'
//!     `queue_set_slots` (typically data queue capacity + close notification queue).
//!   - **std (kqueue/epoll)**: kept for API compatibility; backend may ignore this
//!     value or map it to internal poll limits.
//!   For cross-platform code, always compute it as the sum of `channel.queue_set_slots`
//!   instead of hard-coded formulas.
//!
//! ## Platform Implementations
//!
//! - **std (macOS)**: kqueue + pipe fd (max_events is ignored but kept for API consistency)
//! - **std (Linux)**: epoll + eventfd (max_events is ignored but kept for API consistency)
//! - **ESP32/FreeRTOS**: xQueueSet (max_events must be accurate)
//! - **BK7258/FreeRTOS**: xQueueSet (max_events must be accurate)
//!
//! ## Semantics
//!
//! ### addRecv capacity validation
//! Implementations SHOULD validate that adding a channel would not exceed `max_events`.
//! If the channel's `queue_set_slots` would cause total required slots to exceed
//! `max_events`, return `error.QueueSetCapacityExceeded` (or platform equivalent).
//!
//! ### pre-existing data policy
//! When `addRecv` is called on a channel that already has messages (pre-existing data):
//! - The channel MUST be considered immediately ready
//! - The next `wait()` call MUST return this channel's index without blocking
//! - Implementations may defer queue-set attachment internally, but external behavior
//!   must match the immediate-ready contract
//!
//! ### wait return semantics
//! `wait(timeout_ms)` returns the index of a ready source, or an error:
//! - `error.Empty`: No sources have been added to the selector
//! - Platform-specific errors (e.g., `error.PollWaitFailed`, `error.Interrupted`):
//!   Indicate underlying system failure, NOT timeout
//!
//! ### Timeout handling
//! If `timeout_ms` is provided and no source becomes ready within that duration:
//! - If a timeout source was registered via `addTimeout()`, return its index
//! - Otherwise, return sentinel `max_sources`
//!
//! For `wait(null)` (infinite wait):
//! - If backend wait returns "no event" unexpectedly, implementations MUST return
//!   an error (e.g., `error.PollWaitFailed`) instead of timeout sentinel
//!
//! ### Error handling consistency
//! - `addRecv`: Returns `error.TooMany` if `max_sources` exceeded;
//!   `error.QueueAddFailed` for underlying queue errors;
//!   `error.QueueSetCapacityExceeded` for capacity validation failures
//! - `addTimeout`: Returns `error.TooMany` if `max_sources` exceeded
//!
//! ## Usage
//!
//! ```zig
//! const platform = @import("platform");
//! const Channel = platform.Channel(u32, 4);  // capacity 4
//! const Selector = platform.Selector(3, 3 * Channel.queue_set_slots);  // 3 channels, 15 slots
//!
//! var sel = try Selector.init();
//! defer sel.deinit();
//!
//! try sel.addRecv(&ch1);
//! try sel.addRecv(&ch2);
//! const timeout_idx = try sel.addTimeout(100);  // 100ms timeout
//!
//! const idx = try sel.wait(null);
//!
//! switch (idx) {
//!     0 => { const v = ch1.recv(); },
//!     1 => { const v = ch2.recv(); },
//!     timeout_idx => { /* timeout */ },
//!     else => {},
//! }
//! ```

/// Validate that Impl is a valid Selector type for max_sources.
///
/// Required methods:
/// - `init() -> !Self`
/// - `deinit(*Self) -> void`
/// - `addRecv(*Self, anytype) anyerror!usize`
/// - `addTimeout(*Self, u32) error{TooMany}!usize`
/// - `wait(*Self, ?u32) anyerror!usize`
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
