//! Audio library for embed-zig
//!
//! Provides Zig bindings for audio codecs and containers:
//! - Opus: High-quality audio codec for speech and music
//! - Ogg: Container format for audio streams

pub const opus = @import("opus.zig");
pub const ogg = @import("ogg.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
