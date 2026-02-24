//! Audio library for embed-zig
//!
//! - resampler: Sample rate + channel conversion (SpeexDSP)
//! - stream: Generic encode/decode loops (codec-agnostic)
//! - ogg: Ogg container bindings
//!
//! Opus codec: see //third_party/opus (opus_fixed / opus_float)
//! SpeexDSP: see //third_party/speexdsp (speexdsp_fixed / speexdsp_float)

pub const resampler = @import("resampler.zig");
pub const stream = @import("stream.zig");
pub const ogg = @import("ogg.zig");
pub const mixer = @import("mixer.zig");

pub const Format = resampler.Format;
pub const Resampler = resampler.Resampler;
pub const StreamResampler = resampler.StreamResampler;

test {
    @import("std").testing.refAllDecls(@This());
}
