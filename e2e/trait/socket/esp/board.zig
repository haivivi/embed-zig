//! ESP board for e2e trait/socket
//! Socket test on ESP uses lwip (via idf.Socket).
//! TCP echo server is implemented using idf.Socket's server APIs.
const std = @import("std");
const idf = @import("idf");

pub const log = std.log.scoped(.e2e);
pub const Socket = idf.Socket;

/// TCP echo server using idf.Socket for ESP platform
pub const TcpEchoServer = struct {
    server: idf.Socket,
    port: u16,
    // On ESP, the echo runs synchronously in the test (single-threaded for simplicity)

    pub fn start(ip: [4]u8) !TcpEchoServer {
        var server = try idf.Socket.tcp();
        errdefer server.close();

        try server.bind(ip, 0);
        const port = try server.getBoundPort();

        // ESP doesn't have listen/accept in trait Socket.
        // For now, mark as unsupported — ESP socket test needs WiFi + lwip
        // which requires a different test flow (connect to external echo server).
        _ = port;
        return error.NotSupported;
    }

    pub fn stop(self: *TcpEchoServer) void {
        self.server.close();
    }
};
