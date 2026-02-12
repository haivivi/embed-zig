//! Sync Trait — Mutex and Condition Variable contracts
//!
//! Validates that a Runtime type provides proper synchronization primitives.
//! Used by cross-platform packages (channel, waitgroup) to abstract over
//! platform-specific threading implementations.
//!
//! ## Mutex Contract
//!
//! ```zig
//! const Mutex = struct {
//!     pub fn init() Mutex;
//!     pub fn deinit(self: *Mutex) void;
//!     pub fn lock(self: *Mutex) void;
//!     pub fn unlock(self: *Mutex) void;
//! };
//! ```
//!
//! ## Condition Contract
//!
//! ```zig
//! const Condition = struct {
//!     pub fn init() Condition;
//!     pub fn deinit(self: *Condition) void;
//!     pub fn wait(self: *Condition, mutex: *Mutex) void;
//!     pub fn signal(self: *Condition) void;
//!     pub fn broadcast(self: *Condition) void;
//! };
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // In cross-platform package:
//! pub fn Channel(comptime T: type, comptime N: usize, comptime Rt: type) type {
//!     const M = sync.Mutex(Rt.Mutex);       // validate & get type
//!     const C = sync.Condition(Rt.Condition, M); // validate & get type
//!     return struct {
//!         mutex: M,
//!         cond: C,
//!         // ...
//!     };
//! }
//! ```

/// Validate that Impl is a valid Mutex type
///
/// Required methods:
/// - `init() -> Mutex`
/// - `deinit(*Mutex) -> void`
/// - `lock(*Mutex) -> void`
/// - `unlock(*Mutex) -> void`
pub fn Mutex(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) void, &Impl.lock);
        _ = @as(*const fn (*Impl) void, &Impl.unlock);
    }
    return Impl;
}

/// Validate that Impl is a valid Condition type for the given Mutex
///
/// Required methods:
/// - `init() -> Condition`
/// - `deinit(*Condition) -> void`
/// - `wait(*Condition, *Mutex) -> void`
/// - `signal(*Condition) -> void`
/// - `broadcast(*Condition) -> void`
///
/// Optional (for timeout support):
/// - `timedWait(*Condition, *Mutex, timeout_ns: u64) -> TimedWaitResult`
///   where TimedWaitResult is an enum with `.timed_out` variant.
pub fn Condition(comptime Impl: type, comptime MutexImpl: type) type {
    comptime {
        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl, *MutexImpl) void, &Impl.wait);
        _ = @as(*const fn (*Impl) void, &Impl.signal);
        _ = @as(*const fn (*Impl) void, &Impl.broadcast);
    }
    return Impl;
}
