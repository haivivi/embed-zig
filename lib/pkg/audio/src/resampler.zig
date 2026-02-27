//! Resampler module entry (compatibility bridge)
//!
//! Real implementation moved to `resampler/mod.zig`.

const impl = @import("resampler/mod.zig");

pub const Format = impl.Format;
pub const Resampler = impl.Resampler;
pub const StreamResampler = impl.StreamResampler;
pub const stereoToMono = impl.stereoToMono;
pub const monoToStereo = impl.monoToStereo;
