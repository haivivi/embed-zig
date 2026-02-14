//! ESP board for e2e trait/socket
//! Note: socket test requires WiFi connection first.
//! The test uses localhost only, but ESP TCP/UDP still needs lwip initialized.
const std = @import("std");
const idf = @import("idf");

pub const log = std.log.scoped(.e2e);
pub const Socket = idf.Socket;
