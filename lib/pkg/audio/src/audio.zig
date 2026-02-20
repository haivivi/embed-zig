//! Audio processing library for embed-zig
//!
//! Cross-platform audio engine modules:
//! - **mixer**: Multi-track audio mixer with per-track gain/resample
//! - **aec**: Acoustic Echo Cancellation (SpeexDSP wrapper)
//! - **ns**: Noise Suppression (SpeexDSP wrapper)
//! - **resampler**: Sample rate + channel conversion (SpeexDSP wrapper)
//! - **drc**: Dynamic Range Compression (pure Zig)
//! - **engine**: AudioEngine — 2-task pipeline (speaker + mic)
//! - **stream**: Generic encode/decode loops (codec-agnostic)
//! - **ogg**: Ogg container bindings
//!
//! Opus codec: see //third_party/opus (opus_fixed / opus_float)
//! SpeexDSP: see //third_party/speexdsp (speexdsp_fixed / speexdsp_float)

pub const resampler = @import("resampler.zig");
pub const mixer = @import("mixer.zig");
pub const aec = @import("aec.zig");
pub const ns = @import("ns.zig");
pub const drc = @import("drc.zig");
pub const engine = @import("engine.zig");
pub const stream = @import("stream.zig");
pub const ogg = @import("ogg.zig");

pub const Format = resampler.Format;
pub const Resampler = resampler.Resampler;
pub const StreamResampler = resampler.StreamResampler;
pub const Mixer = mixer.Mixer;
pub const Aec = aec.Aec;
pub const NoiseSuppressor = ns.NoiseSuppressor;
pub const Drc = drc.Drc;
pub const AudioEngine = engine.AudioEngine;

test {
    @import("std").testing.refAllDecls(@This());
}
