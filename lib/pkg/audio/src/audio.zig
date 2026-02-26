//! Audio processing library for embed-zig
//!
//! Cross-platform audio engine modules:
//! - **mixer**: Multi-track audio mixer with per-track gain/resample
//! - **processor**: Unified AEC/NS processor contract + default implementation
//! - **resampler**: Sample rate + channel conversion (pure Zig sinc)
//! - **drc**: Dynamic Range Compression (pure Zig)
//! - **engine**: AudioEngine — 2-task pipeline (speaker + mic)
//! - **stream**: Generic encode/decode loops (codec-agnostic)
//! - **ogg**: Ogg container bindings
//!
//! Opus codec: see //third_party/opus (opus_fixed / opus_float)
pub const resampler = @import("resampler.zig");
pub const mixer = @import("mixer.zig");
pub const processor = @import("processor.zig");
pub const drc = @import("drc.zig");
pub const engine = @import("engine.zig");
pub const stream = @import("stream.zig");
pub const ogg = @import("ogg.zig");

pub const Format = resampler.Format;
pub const Resampler = resampler.Resampler;
pub const StreamResampler = resampler.StreamResampler;
pub const Mixer = mixer.Mixer;
pub const ProcessorConfig = processor.Config;
pub const PassthroughProcessor = processor.PassthroughProcessor;
pub const Drc = drc.Drc;
pub const AudioEngine = engine.AudioEngine;
pub const EngineConfig = engine.EngineConfig;
pub const sim_audio = @import("sim_audio.zig");
pub const SimAudio = sim_audio.SimAudio;

test {
    @import("std").testing.refAllDecls(@This());
}
