//! ESP board for e2e trait/codec
const std = @import("std");
const idf = @import("idf");
const opus_codec = @import("opus_codec.zig");

pub const log = std.log.scoped(.e2e);
pub const heap_allocator = idf.heap.psram;
pub const Codec = opus_codec;
