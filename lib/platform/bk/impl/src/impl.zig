//! BK7258 Implementations of trait and hal interfaces
//!
//! This module provides BK7258-specific implementations that can be used with
//! the trait and hal interface validators.
//!
//! ## trait implementations
//!
//! | Module | Interface | Description |
//! |--------|-----------|-------------|
//! | log | trait.log | Armino BK_LOG* logging |
//! | time | trait.time | Armino RTOS + AON RTC |
//!
//! ## Usage
//!
//! ```zig
//! const impl = @import("impl");
//! const trait = @import("trait");
//!
//! // Use trait implementations
//! const Time = trait.time.from(impl.Time);
//! ```

// ============================================================================
// trait implementations
// ============================================================================

/// Log implementation (trait.log)
pub const log = @import("log.zig");
pub const Log = log.Log;
pub const stdLogFn = log.stdLogFn;

/// Time implementation (trait.time)
pub const time = @import("time.zig");
pub const Time = time.Time;
