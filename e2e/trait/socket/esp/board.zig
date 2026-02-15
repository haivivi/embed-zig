//! ESP board for e2e trait/socket
const std = @import("std");
const idf = @import("idf");

pub const log = std.log.scoped(.e2e);
pub const Socket = idf.Socket;
pub const runtime = idf.runtime;
