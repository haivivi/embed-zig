//! Selector — Cross-platform multi-channel wait
//!
//! A Selector allows waiting on multiple channels simultaneously, similar to
//! Go's `select` or Rust's `tokio::select!`.
//!
//! ## Usage
//!
//! ```zig
//! const selector = @import("selector");
//! const Selector = selector.Selector;
//! const Channel = selector.Channel;
//!
//! var sel = Selector(3, 32).init();
//! defer sel.deinit();
//!
//! const idx1 = try sel.addRecv(&ch1);
//! const idx2 = try sel.addRecv(&ch2);
//! const timeout_idx = try sel.addTimeout(100);
//!
//! const ready = try sel.wait(null);
//! switch (ready) {
//!     idx1 => { const v = ch1.recv(); },
//!     idx2 => { const v = ch2.recv(); },
//!     timeout_idx => { /* timeout */ },
//!     else => unreachable,
//! }
//! ```
//!
//! ## Platform Support
//!
//! - **std (macOS)**: kqueue + pipe
//! - **std (Linux)**: epoll + eventfd
//! - **ESP32**: FreeRTOS xQueueSet
//! - **BK7258**: FreeRTOS xQueueSet

const std = @import("std");

/// Re-export platform-specific implementations
///
/// Applications should use the platform module to get the correct implementation:
/// ```zig
/// const platform = @import("platform");
/// const Selector = platform.selector.Selector;
/// const Channel = platform.channel.Channel;
/// ```
/// Test imports for cross-platform validation
pub const trait = @import("trait");

/// Validate that a platform implementation satisfies the Selector trait.
/// This can be used in platform code to ensure compatibility.
pub fn validatePlatformSelector(comptime SelectorType: type) void {
    trait.selector.validate(SelectorType);
}

/// Validate that a platform implementation satisfies the Channel trait.
/// This can be used in platform code to ensure compatibility.
pub fn validatePlatformChannel(comptime T: type, comptime ChannelType: type) void {
    trait.channel.validate(T, ChannelType);
}

// ============================================================================
// Tests
// ============================================================================

// Platform-specific tests are in the respective platform implementations.
// This module provides trait validation only.

test "trait validation exports" {
    // Just verify the exports exist
    _ = validatePlatformSelector;
    _ = validatePlatformChannel;
}
