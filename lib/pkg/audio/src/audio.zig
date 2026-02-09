//! Audio library for embed-zig
//!
//! - stream: Generic encode/decode loops (codec-agnostic)
//! - ogg: Ogg container bindings
//!
//! Opus codec: see //third_party/opus (opus_fixed / opus_float)

pub const stream = @import("stream.zig");
pub const ogg = @import("ogg.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
