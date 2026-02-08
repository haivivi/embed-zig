//! Audio library for embed-zig
//!
//! - opus: Opus codec bindings (allocator-based)
//! - ogg: Ogg container bindings
//! - stream: Generic encode/decode loops (codec-agnostic)

pub const opus = @import("opus.zig");
pub const ogg = @import("ogg.zig");
pub const stream = @import("stream.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
