//! ESP board for e2e trait/log
const std = @import("std");
pub const log = std.log.scoped(.e2e);
