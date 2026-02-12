//! TLS Stream Adapter
//!
//! Provides a stream interface compatible with lib/http's TLS requirements.
//! Wraps the TLS Client to provide send/recv/handshake methods.
//! Crypto must include Rng (Crypto.Rng.fill).

const std = @import("std");
const tls_client = @import("client.zig");
const common = @import("common.zig");

/// TLS Stream Options (compatible with HTTP client expectations)
pub const Options = struct {
    skip_cert_verify: bool = false,
    timeout_ms: u32 = 30000,
};

/// Create a TLS Stream type for use with HTTP client
///
/// Usage:
/// ```zig
/// const TlsStream = tls.Stream(Socket, Crypto, Rt, allocator);
/// const HttpClient = http.ClientWithTls(Socket, TlsStream);
/// ```
pub fn Stream(comptime Socket: type, comptime Crypto: type, comptime Rt: type, comptime allocator: std.mem.Allocator) type {
    return struct {
        client: tls_client.Client(Socket, Crypto, Rt),
        socket: Socket,
        hostname: []const u8,

        const Self = @This();

        /// Initialize TLS stream with socket and options
        pub fn init(socket: Socket, options: Options) !Self {
            var self = Self{
                .socket = socket,
                .client = undefined,
                .hostname = "",
            };

            const config = tls_client.Config(Crypto){
                .allocator = allocator,
                .hostname = "",
                .skip_verify = options.skip_cert_verify,
                .timeout_ms = options.timeout_ms,
            };

            self.client = try tls_client.Client(Socket, Crypto, Rt).init(&self.socket, config);
            return self;
        }

        /// Clean up TLS stream
        pub fn deinit(self: *Self) void {
            self.client.close() catch {};
            self.client.deinit();
        }

        /// Perform TLS handshake
        pub fn handshake(self: *Self, hostname: []const u8) !void {
            self.hostname = hostname;
            // Update hostname in the handshake state
            self.client.hs.hostname = hostname;
            try self.client.connect();
        }

        /// Send data over TLS
        pub fn send(self: *Self, data: []const u8) !usize {
            return self.client.send(data);
        }

        /// Receive data over TLS
        pub fn recv(self: *Self, buffer: []u8) !usize {
            return self.client.recv(buffer);
        }
    };
}

/// Create a TLS Stream with runtime allocator
///
/// For embedded systems where allocator needs to be configurable at runtime.
pub fn StreamWithAllocator(comptime Socket: type, comptime Crypto: type, comptime Rt: type) type {
    return struct {
        client: ?tls_client.Client(Socket, Crypto, Rt),
        socket: *Socket,
        allocator: std.mem.Allocator,
        hostname: []const u8,

        const Self = @This();

        /// Initialize TLS stream with socket, allocator, and options
        pub fn init(socket: *Socket, alloc: std.mem.Allocator, options: Options) !Self {
            var self = Self{
                .socket = socket,
                .client = null,
                .allocator = alloc,
                .hostname = "",
            };

            const config = tls_client.Config(Crypto){
                .allocator = alloc,
                .hostname = "",
                .skip_verify = options.skip_cert_verify,
                .timeout_ms = options.timeout_ms,
            };

            self.client = try tls_client.Client(Socket, Crypto, Rt).init(socket, config);
            return self;
        }

        /// Clean up TLS stream
        pub fn deinit(self: *Self) void {
            if (self.client) |*c| {
                c.close() catch {};
                c.deinit();
            }
        }

        /// Perform TLS handshake
        pub fn handshake(self: *Self, hostname: []const u8) !void {
            self.hostname = hostname;
            if (self.client) |*c| {
                c.hs.hostname = hostname;
                try c.connect();
            }
        }

        /// Send data over TLS
        pub fn send(self: *Self, data: []const u8) !usize {
            if (self.client) |*c| {
                return c.send(data);
            }
            return error.NotConnected;
        }

        /// Receive data over TLS
        pub fn recv(self: *Self, buffer: []u8) !usize {
            if (self.client) |*c| {
                return c.recv(buffer);
            }
            return error.NotConnected;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Options defaults" {
    const opts = Options{};
    try std.testing.expectEqual(false, opts.skip_cert_verify);
    try std.testing.expectEqual(@as(u32, 30000), opts.timeout_ms);
}
