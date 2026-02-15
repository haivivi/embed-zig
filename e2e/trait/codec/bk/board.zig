//! BK board for e2e trait/codec
const bk = @import("bk");
const opus_codec = @import("opus_codec.zig");
pub const log = bk.impl.log.scoped("e2e");
pub const heap_allocator = bk.armino.heap.psram;
pub const Codec = opus_codec;
