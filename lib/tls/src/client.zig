//! TLS Client
//!
//! High-level TLS client API for establishing secure connections.
//! Supports TLS 1.2 and TLS 1.3.
//!
//! ## Crypto Abstraction
//!
//! The client accepts a Crypto type parameter for cryptographic primitives.
//! Provide a crypto implementation that satisfies trait.crypto interface.
//! The Crypto type must include Rng (Crypto.Rng.fill).
//!
//! ```zig
//! const Crypto = Board.crypto; // or any trait.crypto compatible implementation
//! const TlsClient = tls.Client(Socket, Crypto);
//! ```

const std = @import("std");
const trait = @import("trait");
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

/// Client configuration
/// Generic over Crypto to support different x509 implementations
pub fn Config(comptime Crypto: type) type {
    // Get CaStore type from Crypto if available, otherwise use void (no cert verification)
    const CaStore = if (@hasDecl(Crypto, "x509") and @hasDecl(Crypto.x509, "CaStore"))
        Crypto.x509.CaStore
    else
        void;

    return struct {
        /// Memory allocator for TLS operations
        allocator: std.mem.Allocator,

        /// Server hostname for SNI and certificate verification
        hostname: []const u8 = "",

        /// Skip certificate verification (INSECURE - for testing only)
        skip_verify: bool = false,

        /// CA store for certificate verification
        ca_store: ?CaStore = null,

        /// ALPN protocols (e.g., "h2", "http/1.1")
        alpn_protocols: []const []const u8 = &.{},

        /// Minimum TLS version (default: TLS 1.2)
        min_version: ProtocolVersion = .tls_1_2,

        /// Maximum TLS version (default: TLS 1.3)
        max_version: ProtocolVersion = .tls_1_3,

        /// Timeout in milliseconds (0 = no timeout)
        timeout_ms: u32 = 30000,
    };
}


// ============================================================================
// TLS Client
// ============================================================================

/// TLS Client - provides secure communication over a socket
///
/// Generic over Socket type to support different platforms (ESP32, std, etc.)
/// Crypto parameter allows custom cryptographic implementations (e.g., hardware acceleration).
///
/// Type parameters:
/// - Socket: Platform socket type (must implement trait.socket interface)
/// - Crypto: Cryptographic primitives (must include Rng, default: crypto.Suite for pure Zig)
pub fn Client(comptime Socket: type, comptime Crypto: type) type {
    // Validate Crypto implementation at compile time
    comptime {
        _ = trait.crypto.from(Crypto, .{
            .sha256 = true,
            .aes_128_gcm = true,
            .x25519 = true,
            .hkdf_sha256 = true,
            .hmac_sha256 = true,
            .rng = true,
        });
    }

    return struct {
        config: Config(Crypto),
        socket: *Socket,
        hs: handshake.ClientHandshake(Socket, Crypto),
        connected: bool,
        received_close_notify: bool,

        // Buffers
        read_buffer: []u8,
        write_buffer: []u8,

        const Self = @This();

        /// The crypto implementation being used
        pub const crypto = Crypto;

        /// Initialize a TLS client
        pub fn init(socket: *Socket, config: Config(Crypto)) !Self {
            // Allocate buffers
            const read_buffer = try config.allocator.alloc(u8, common.MAX_CIPHERTEXT_LEN + 256);
            errdefer config.allocator.free(read_buffer);

            const write_buffer = try config.allocator.alloc(u8, common.MAX_CIPHERTEXT_LEN + 256);
            errdefer config.allocator.free(write_buffer);

            // Pass ca_store to handshake if Crypto supports x509
            const Hs = handshake.ClientHandshake(Socket, Crypto);
            const hs_ca_store: if (Hs.CaStoreType != void) ?Hs.CaStoreType else void = 
                if (Hs.CaStoreType != void) config.ca_store else {};

            return Self{
                .config = config,
                .socket = socket,
                .hs = Hs.init(
                    socket,
                    config.hostname,
                    config.allocator,
                    hs_ca_store,
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

            // Use a loop instead of recursion to avoid stack overflow
            // from malicious servers sending many handshake messages
            while (true) {
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
                            // Safe conversion - unknown alert types just return error
                            if (std.meta.intToEnum(AlertDescription, plaintext[1])) |desc| {
                                if (desc == .close_notify) {
                                    self.received_close_notify = true;
                                    return 0;
                                }
                            } else |_| {}
                        }
                        return error.AlertReceived;
                    },
                    .handshake => {
                        // Post-handshake messages (key update, new session ticket)
                        // Ignore and continue reading
                        continue;
                    },
                    else => return error.UnexpectedMessage,
                }
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
    CertificateVerificationFailed,
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Create a TLS client with standard configuration
pub fn connect(
    comptime Socket: type,
    comptime Crypto: type,
    socket: *Socket,
    hostname: []const u8,
    allocator: std.mem.Allocator,
) !Client(Socket, Crypto) {
    var tls_client = try Client(Socket, Crypto).init(socket, .{
        .allocator = allocator,
        .hostname = hostname,
    });
    errdefer tls_client.deinit();

    try tls_client.connect();
    return tls_client;
}


// ============================================================================
// Tests
// ============================================================================

test "Config defaults" {
    // Mock crypto for testing
    const MockCrypto = struct {
        pub const Sha256 = struct {
            pub const digest_length = 32;
            pub fn init() @This() { return .{}; }
            pub fn update(_: *@This(), _: []const u8) void {}
            pub fn final(_: *@This()) [32]u8 { return [_]u8{0} ** 32; }
            pub fn hash(_: []const u8, _: *[32]u8, _: anytype) void {}
        };
        pub const Aes128Gcm = struct {
            pub const key_length = 16;
            pub const nonce_length = 12;
            pub const tag_length = 16;
            pub fn encryptStatic(_: []u8, _: *[16]u8, _: []const u8, _: []const u8, _: [12]u8, _: [16]u8) void {}
            pub fn decryptStatic(_: []u8, _: []const u8, _: [16]u8, _: []const u8, _: [12]u8, _: [16]u8) error{AuthenticationFailed}!void {}
        };
        pub const X25519 = struct {
            pub const secret_length = 32;
            pub const public_length = 32;
            pub const KeyPair = struct {
                secret_key: [32]u8,
                public_key: [32]u8,
                pub fn generateDeterministic(_: [32]u8) !@This() { return .{ .secret_key = undefined, .public_key = undefined }; }
            };
            pub fn scalarmult(_: [32]u8, _: [32]u8) ![32]u8 { return [_]u8{0} ** 32; }
        };
        pub const HkdfSha256 = struct {
            pub const prk_length = 32;
            pub fn extract(_: ?[]const u8, _: []const u8) [32]u8 { return [_]u8{0} ** 32; }
            pub fn expand(_: *const [32]u8, _: []const u8, comptime _: usize) [32]u8 { return [_]u8{0} ** 32; }
        };
        pub const HmacSha256 = struct {
            pub const mac_length = 32;
            pub fn create(_: *[32]u8, _: []const u8, _: []const u8) void {}
            pub fn init(_: []const u8) @This() { return .{}; }
        };
        pub const Rng = struct {
            pub fn fill(_: []u8) void {}
        };
    };

    const TestConfig = Config(MockCrypto);
    const config: TestConfig = .{
        .allocator = std.testing.allocator,
        .hostname = "example.com",
    };

    try std.testing.expectEqual(ProtocolVersion.tls_1_2, config.min_version);
    try std.testing.expectEqual(ProtocolVersion.tls_1_3, config.max_version);
    try std.testing.expectEqual(false, config.skip_verify);
}
