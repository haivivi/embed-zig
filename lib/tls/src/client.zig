//! TLS Client
//!
//! High-level TLS client API for establishing secure connections.
//! Supports TLS 1.2 and TLS 1.3.

const std = @import("std");
const crypto = @import("crypto");
const common = @import("common.zig");
const record = @import("record.zig");
const handshake = @import("handshake.zig");

const ProtocolVersion = common.ProtocolVersion;
const CipherSuite = common.CipherSuite;
const ContentType = common.ContentType;
const AlertDescription = common.AlertDescription;
const AlertLevel = common.AlertLevel;

// ============================================================================
// Client Configuration
// ============================================================================

pub const Config = struct {
    /// Memory allocator for TLS operations
    allocator: std.mem.Allocator,

    /// Server hostname for SNI and certificate verification
    hostname: []const u8 = "",

    /// Skip certificate verification (INSECURE - for testing only)
    skip_verify: bool = false,

    /// CA store for certificate verification
    ca_store: ?crypto.x509.CaStore = null,

    /// ALPN protocols (e.g., "h2", "http/1.1")
    alpn_protocols: []const []const u8 = &.{},

    /// Minimum TLS version (default: TLS 1.2)
    min_version: ProtocolVersion = .tls_1_2,

    /// Maximum TLS version (default: TLS 1.3)
    max_version: ProtocolVersion = .tls_1_3,

    /// Timeout in milliseconds (0 = no timeout)
    timeout_ms: u32 = 30000,
};

// ============================================================================
// TLS Client
// ============================================================================

/// TLS Client - provides secure communication over a socket
///
/// Generic over Socket type to support different platforms (ESP32, std, etc.)
pub fn Client(comptime Socket: type, comptime Rng: type) type {
    return struct {
        config: Config,
        socket: *Socket,
        hs: handshake.ClientHandshake(Socket, Rng),
        connected: bool,
        received_close_notify: bool,

        // Buffers
        read_buffer: []u8,
        write_buffer: []u8,

        const Self = @This();

        /// Initialize a TLS client
        pub fn init(socket: *Socket, config: Config) !Self {
            // Allocate buffers
            const read_buffer = try config.allocator.alloc(u8, common.MAX_CIPHERTEXT_LEN + 256);
            errdefer config.allocator.free(read_buffer);

            const write_buffer = try config.allocator.alloc(u8, common.MAX_CIPHERTEXT_LEN + 256);
            errdefer config.allocator.free(write_buffer);

            return Self{
                .config = config,
                .socket = socket,
                .hs = handshake.ClientHandshake(Socket, Rng).init(
                    socket,
                    config.hostname,
                    config.allocator,
                ),
                .connected = false,
                .received_close_notify = false,
                .read_buffer = read_buffer,
                .write_buffer = write_buffer,
            };
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            self.config.allocator.free(self.read_buffer);
            self.config.allocator.free(self.write_buffer);
        }

        /// Perform TLS handshake
        pub fn connect(self: *Self) !void {
            try self.hs.handshake(self.write_buffer);
            self.connected = true;
        }

        /// Send encrypted data
        pub fn send(self: *Self, data: []const u8) !usize {
            if (!self.connected) return error.NotConnected;
            if (self.received_close_notify) return error.ConnectionClosed;

            // Send data in chunks if necessary
            var sent: usize = 0;
            while (sent < data.len) {
                const chunk_size = @min(data.len - sent, common.MAX_PLAINTEXT_LEN);
                _ = try self.hs.records.writeRecord(
                    .application_data,
                    data[sent..][0..chunk_size],
                    self.write_buffer,
                );
                sent += chunk_size;
            }
            return sent;
        }

        /// Receive and decrypt data
        pub fn recv(self: *Self, buffer: []u8) !usize {
            if (!self.connected) return error.NotConnected;
            if (self.received_close_notify) return 0;

            var plaintext: [common.MAX_CIPHERTEXT_LEN]u8 = undefined;
            const result = try self.hs.records.readRecord(self.read_buffer, &plaintext);

            switch (result.content_type) {
                .application_data => {
                    const copy_len = @min(result.length, buffer.len);
                    @memcpy(buffer[0..copy_len], plaintext[0..copy_len]);
                    return copy_len;
                },
                .alert => {
                    if (result.length >= 2) {
                        const desc: AlertDescription = @enumFromInt(plaintext[1]);
                        if (desc == .close_notify) {
                            self.received_close_notify = true;
                            return 0;
                        }
                    }
                    return error.AlertReceived;
                },
                .handshake => {
                    // Post-handshake messages (key update, new session ticket)
                    // For now, just ignore and try to read again
                    return self.recv(buffer);
                },
                else => return error.UnexpectedMessage,
            }
        }

        /// Send close_notify alert and close connection
        pub fn close(self: *Self) !void {
            if (self.connected and !self.received_close_notify) {
                try self.hs.records.sendAlert(
                    .warning,
                    .close_notify,
                    self.write_buffer,
                );
            }
            self.connected = false;
        }

        /// Get the negotiated protocol version
        pub fn getVersion(self: *Self) ProtocolVersion {
            return self.hs.version;
        }

        /// Get the negotiated cipher suite
        pub fn getCipherSuite(self: *Self) CipherSuite {
            return self.hs.cipher_suite;
        }

        /// Check if connection is established
        pub fn isConnected(self: *Self) bool {
            return self.connected and !self.received_close_notify;
        }
    };
}

// ============================================================================
// Errors
// ============================================================================

pub const Error = error{
    NotConnected,
    ConnectionClosed,
    AlertReceived,
    UnexpectedMessage,
    HandshakeFailed,
    OutOfMemory,
    BufferTooSmall,
    InvalidHandshake,
    UnsupportedGroup,
    InvalidPublicKey,
    HelloRetryNotSupported,
    UnsupportedCipherSuite,
    InvalidKeyLength,
    InvalidIvLength,
    RecordTooLarge,
    DecryptionFailed,
    BadRecordMac,
    UnexpectedRecord,
    IdentityElement,
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Create a TLS client with standard configuration
pub fn connect(
    comptime Socket: type,
    comptime Rng: type,
    socket: *Socket,
    hostname: []const u8,
    allocator: std.mem.Allocator,
) !Client(Socket, Rng) {
    var client = try Client(Socket, Rng).init(socket, .{
        .allocator = allocator,
        .hostname = hostname,
    });
    errdefer client.deinit();

    try client.connect();
    return client;
}

// ============================================================================
// Tests
// ============================================================================

test "Config defaults" {
    const config = Config{
        .allocator = std.testing.allocator,
        .hostname = "example.com",
    };

    try std.testing.expectEqual(ProtocolVersion.tls_1_2, config.min_version);
    try std.testing.expectEqual(ProtocolVersion.tls_1_3, config.max_version);
    try std.testing.expectEqual(false, config.skip_verify);
}
