//! Sync Trait — Mutex, Condition Variable, and Notify contracts
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
//!     pub const TimedWaitResult = enum { signaled, timed_out };
//!     pub fn init() Condition;
//!     pub fn deinit(self: *Condition) void;
//!     pub fn wait(self: *Condition, mutex: *Mutex) void;
//!     pub fn signal(self: *Condition) void;
//!     pub fn broadcast(self: *Condition) void;
//!     pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) TimedWaitResult;
//! };
//! ```
//!
//! ## Notify Contract
//!
//! Lightweight thread notification — faster than Condition (no Mutex needed).
//! Linux: eventfd, macOS: pipe, ESP32: task notification, Windows: Event.
//!
//! ```zig
//! const Notify = struct {
//!     pub fn init() Notify;
//!     pub fn deinit(self: *Notify) void;
//!     pub fn signal(self: *Notify) void;
//!     pub fn wait(self: *Notify) void;
//!     pub fn timedWait(self: *Notify, timeout_ns: u64) bool;
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
/// - `timedWait(*Condition, *Mutex, timeout_ns: u64) -> TimedWaitResult`
///   where TimedWaitResult is an enum with `.timed_out` variant.
pub fn Condition(comptime Impl: type, comptime MutexImpl: type) type {
    comptime {
        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl, *MutexImpl) void, &Impl.wait);
        _ = @as(*const fn (*Impl) void, &Impl.signal);
        _ = @as(*const fn (*Impl) void, &Impl.broadcast);
        _ = @as(*const fn (*Impl, *MutexImpl, u64) Impl.TimedWaitResult, &Impl.timedWait);
    }
    return Impl;
}

/// Validate that Impl is a valid Notify type
///
/// Lightweight event notification — no Mutex required.
///
/// Required methods:
/// - `init() -> Notify`
/// - `deinit(*Notify) -> void`
/// - `signal(*Notify) -> void` — wake the waiter
/// - `wait(*Notify) -> void` — block until signaled
/// - `timedWait(*Notify, timeout_ns: u64) -> bool` — true if signaled, false if timed out
pub fn Notify(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) void, &Impl.signal);
        _ = @as(*const fn (*Impl) void, &Impl.wait);
        _ = @as(*const fn (*Impl, u64) bool, &Impl.timedWait);
    }
    return Impl;
}
