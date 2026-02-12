//! CancellationToken — Cooperative cancellation signal
//!
//! Pure atomic implementation, zero dependencies beyond Zig builtins.
//! Used to signal long-running tasks to exit gracefully.
//!
//! ## Usage
//!
//! ```zig
//! var token = CancellationToken.init();
//!
//! // In task loop:
//! while (!token.isCancelled()) {
//!     // do work
//! }
//!
//! // From controller:
//! token.cancel();
//! ```
//!
//! ## Thread Safety
//!
//! All methods are safe to call from any thread. Uses acquire/release
//! ordering to ensure visibility of cancellation across threads.

const std = @import("std");

/// Cooperative cancellation signal using atomic boolean.
/// Safe to share across threads without additional synchronization.
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool),

    /// Initialize a new token (not cancelled)
    pub fn init() CancellationToken {
        return .{ .cancelled = std.atomic.Value(bool).init(false) };
    }

    /// Check if cancellation has been requested
    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }

    /// Request cancellation (thread-safe, idempotent)
    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    /// Reset to non-cancelled state
    pub fn reset(self: *CancellationToken) void {
        self.cancelled.store(false, .release);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CancellationToken basic" {
    var token = CancellationToken.init();

    // Initially not cancelled
    try std.testing.expect(!token.isCancelled());

    // After cancel, should be cancelled
    token.cancel();
    try std.testing.expect(token.isCancelled());

    // Idempotent cancel
    token.cancel();
    try std.testing.expect(token.isCancelled());

    // After reset, should not be cancelled
    token.reset();
    try std.testing.expect(!token.isCancelled());
}

test "CancellationToken cross-thread visibility" {
    var token = CancellationToken.init();

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(t: *CancellationToken) void {
            // Spin until cancelled
            while (!t.isCancelled()) {
                std.atomic.spinLoopHint();
            }
        }
    }.run, .{&token});

    // Small delay then cancel
    std.Thread.sleep(1 * std.time.ns_per_ms);
    token.cancel();

    thread.join();

    // Thread exited because it saw the cancellation
    try std.testing.expect(token.isCancelled());
}
