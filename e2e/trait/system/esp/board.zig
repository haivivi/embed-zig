//! ESP board for e2e trait/system
const std = @import("std");
const idf = @import("idf");

pub const log = std.log.scoped(.e2e);
pub const runtime = idf.runtime;
