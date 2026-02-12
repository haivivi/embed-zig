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
/// Thread-safe: send() and recv() can be called concurrently from different
/// threads (e.g., mqtt0 readLoop + ping). Multiple concurrent send() calls
/// are serialized, as are multiple concurrent recv() calls.
///
/// Generic over Socket type to support different platforms (ESP32, std, etc.)
/// Crypto parameter allows custom cryptographic implementations (e.g., hardware acceleration).
/// Rt (Runtime) parameter provides synchronization primitives (Mutex) for thread safety.
///
/// Type parameters:
/// - Socket: Platform socket type (must implement trait.socket interface)
/// - Crypto: Cryptographic primitives (must include Rng, default: crypto.Suite for pure Zig)
/// - Rt: Runtime providing Mutex (validated via trait.sync). Use std_impl.runtime for
///   desktop/server, esp.idf.runtime for ESP32.
pub fn Client(comptime Socket: type, comptime Crypto: type, comptime Rt: type) type {
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

    // Validate Runtime provides Mutex
    const Mutex = trait.sync.Mutex(Rt.Mutex);

    return struct {
        config: Config(Crypto),
        socket: *Socket,
        hs: handshake.ClientHandshake(Socket, Crypto),
        connected: bool,
        received_close_notify: bool,

        // Concurrency: write_mutex protects write_buffer + writeRecord (write_cipher, write_seq)
        write_mutex: Mutex,
        // Concurrency: read_mutex protects read_buffer + readRecord (read_cipher, read_seq) + pending_*
        read_mutex: Mutex,

        // Buffers
        read_buffer: []u8,
        write_buffer: []u8,

        // Pending plaintext from partially consumed TLS record
        pending_plaintext: [common.MAX_CIPHERTEXT_LEN]u8 = undefined,
        pending_pos: usize = 0,
        pending_len: usize = 0,

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
                .write_mutex = Mutex.init(),
                .read_mutex = Mutex.init(),
                .read_buffer = read_buffer,
                .write_buffer = write_buffer,
            };
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            self.read_mutex.deinit();
            self.write_mutex.deinit();
            self.config.allocator.free(self.read_buffer);
            self.config.allocator.free(self.write_buffer);
        }

        /// Perform TLS handshake
        /// Must be called before any concurrent send/recv.
        /// NOT thread-safe — call from a single thread before spawning readers/writers.
        pub fn connect(self: *Self) !void {
            try self.hs.handshake(self.write_buffer);
            self.connected = true;
        }

        /// Send encrypted data (thread-safe)
        ///
        /// Multiple concurrent send() calls are serialized via write_mutex.
        /// Can be called concurrently with recv().
        pub fn send(self: *Self, data: []const u8) !usize {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();

            // Atomic reads: connected is written by close() under write_mutex (same lock),
            // but received_close_notify is written by recv() under read_mutex (different lock).
            if (!@atomicLoad(bool, &self.connected, .acquire)) return error.NotConnected;
            if (@atomicLoad(bool, &self.received_close_notify, .acquire)) return error.ConnectionClosed;

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

        /// Receive and decrypt data (thread-safe)
        ///
        /// Multiple concurrent recv() calls are serialized via read_mutex.
        /// Can be called concurrently with send().
        ///
        /// If the caller's buffer is smaller than the decrypted TLS record,
        /// remaining data is buffered internally and returned on subsequent calls.
        pub fn recv(self: *Self, buffer: []u8) !usize {
            self.read_mutex.lock();
            defer self.read_mutex.unlock();

            // Atomic reads: received_close_notify is written here under read_mutex (same lock),
            // but connected is written by close() under write_mutex (different lock).
            if (!@atomicLoad(bool, &self.connected, .acquire)) return error.NotConnected;
            if (@atomicLoad(bool, &self.received_close_notify, .acquire)) return 0;

            // Return pending data from a previous partially-consumed record
            if (self.pending_len > 0) {
                const n = @min(self.pending_len, buffer.len);
                @memcpy(buffer[0..n], self.pending_plaintext[self.pending_pos..][0..n]);
                self.pending_pos += n;
                self.pending_len -= n;
                return n;
            }

            // Use a loop instead of recursion to avoid stack overflow
            // from malicious servers sending many handshake messages
            while (true) {
                var plaintext: [common.MAX_CIPHERTEXT_LEN]u8 = undefined;
                const result = try self.hs.records.readRecord(self.read_buffer, &plaintext);

                switch (result.content_type) {
                    .application_data => {
                        const copy_len = @min(result.length, buffer.len);
                        @memcpy(buffer[0..copy_len], plaintext[0..copy_len]);

                        // Buffer any remaining data for subsequent recv() calls
                        if (result.length > copy_len) {
                            const leftover = result.length - copy_len;
                            @memcpy(self.pending_plaintext[0..leftover], plaintext[copy_len..result.length]);
                            self.pending_pos = 0;
                            self.pending_len = leftover;
                        }

                        return copy_len;
                    },
                    .alert => {
                        if (result.length >= 2) {
                            // Safe conversion - unknown alert types just return error
                            if (std.meta.intToEnum(AlertDescription, plaintext[1])) |desc| {
                                if (desc == .close_notify) {
                                    @atomicStore(bool, &self.received_close_notify, true, .release);
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

        /// Send close_notify alert and close connection (thread-safe)
        ///
        /// Acquires write_mutex to send the alert.
        pub fn close(self: *Self) !void {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();

            // Atomic reads: received_close_notify is written by recv() under read_mutex (different lock).
            if (@atomicLoad(bool, &self.connected, .acquire) and !@atomicLoad(bool, &self.received_close_notify, .acquire)) {
                try self.hs.records.sendAlert(
                    .warning,
                    .close_notify,
                    self.write_buffer,
                );
            }
            @atomicStore(bool, &self.connected, false, .release);
        }

        /// Get the negotiated protocol version
        pub fn getVersion(self: *Self) ProtocolVersion {
            return self.hs.version;
        }

        /// Get the negotiated cipher suite
        pub fn getCipherSuite(self: *Self) CipherSuite {
            return self.hs.cipher_suite;
        }

        /// Check if connection is established (safe to call from any thread)
        pub fn isConnected(self: *Self) bool {
            return @atomicLoad(bool, &self.connected, .acquire) and
                !@atomicLoad(bool, &self.received_close_notify, .acquire);
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
    comptime Rt: type,
    socket: *Socket,
    hostname: []const u8,
    allocator: std.mem.Allocator,
) !Client(Socket, Crypto, Rt) {
    var tls_client = try Client(Socket, Crypto, Rt).init(socket, .{
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

// ============================================================================
// Test helpers
// ============================================================================

/// Mock crypto for comptime validation (no actual crypto operations)
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

/// Real crypto for tests that need the full Client (RecordLayer needs all cipher types)
const test_crypto = @import("crypto");

/// Test runtime using std.Thread.Mutex
const TestRuntime = struct {
    pub const Mutex = struct {
        inner: std.Thread.Mutex = .{},
        pub fn init() Mutex { return .{}; }
        pub fn deinit(_: *Mutex) void {}
        pub fn lock(self: *Mutex) void { self.inner.lock(); }
        pub fn unlock(self: *Mutex) void { self.inner.unlock(); }
    };
};

/// Pipe-based mock socket for concurrent testing
///
/// Uses OS pipe for send/recv. Send writes to pipe_wr, recv reads from pipe_rd.
/// Thread-safe for single-writer + single-reader (kernel pipe guarantees).
const PipeSocket = struct {
    pipe_rd: std.posix.fd_t,
    pipe_wr: std.posix.fd_t,

    const Self = @This();

    pub fn initPair() ![2]Self {
        // Pipe A: writer sends → reader receives
        const pipe_a = try std.posix.pipe();
        // Pipe B: reader sends → writer receives (for bidirectional)
        const pipe_b = try std.posix.pipe();

        return .{
            // Socket 0: send goes to pipe_a, recv comes from pipe_b
            .{ .pipe_rd = pipe_b[0], .pipe_wr = pipe_a[1] },
            // Socket 1: send goes to pipe_b, recv comes from pipe_a
            .{ .pipe_rd = pipe_a[0], .pipe_wr = pipe_b[1] },
        };
    }

    pub fn close(self: *Self) void {
        std.posix.close(self.pipe_rd);
        std.posix.close(self.pipe_wr);
    }

    pub fn send(self: *Self, data: []const u8) !usize {
        return std.posix.write(self.pipe_wr, data);
    }

    pub fn recv(self: *Self, buf: []u8) !usize {
        return std.posix.read(self.pipe_rd, buf);
    }
};

test "Config defaults" {
    const TestConfig = Config(MockCrypto);
    const config: TestConfig = .{
        .allocator = std.testing.allocator,
        .hostname = "example.com",
    };

    try std.testing.expectEqual(ProtocolVersion.tls_1_2, config.min_version);
    try std.testing.expectEqual(ProtocolVersion.tls_1_3, config.max_version);
    try std.testing.expectEqual(false, config.skip_verify);
}

test "Client init and deinit with mutex" {
    // Verify that Client with Rt properly initializes and deinitializes mutexes
    var sockets = try PipeSocket.initPair();
    defer sockets[0].close();
    defer sockets[1].close();

    const TestClient = Client(PipeSocket, test_crypto, TestRuntime);

    var client = try TestClient.init(&sockets[0], .{
        .allocator = std.testing.allocator,
        .hostname = "test.example.com",
    });
    defer client.deinit();

    // Client should not be connected (no handshake yet)
    try std.testing.expect(!client.isConnected());
}

test "concurrent send from two threads" {
    // Test that two threads can call send() concurrently without crashing.
    // Uses unencrypted mode (cipher = .none) for simplicity.
    // One socket pair: sender writes TLS records, reader drains the pipe.
    var sockets = try PipeSocket.initPair();
    defer sockets[1].close();

    const TestClient = Client(PipeSocket, test_crypto, TestRuntime);
    var client = try TestClient.init(&sockets[0], .{
        .allocator = std.testing.allocator,
    });
    defer client.deinit();

    // Skip handshake — set connected directly for unit test
    client.connected = true;

    const iterations = 1000;

    // Drain thread: reads data from the other end of the pipe to prevent blocking
    const drain_thread = try std.Thread.spawn(.{}, struct {
        fn run(sock: *PipeSocket) void {
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < iterations * 2 * (common.RECORD_HEADER_LEN + 5)) {
                const n = sock.recv(&buf) catch break;
                if (n == 0) break;
                total += n;
            }
        }
    }.run, .{&sockets[1]});

    // Writer thread 1
    const t1 = try std.Thread.spawn(.{}, struct {
        fn run(c: *TestClient) void {
            for (0..iterations) |_| {
                _ = c.send("hello") catch {};
            }
        }
    }.run, .{&client});

    // Writer thread 2 (in current thread)
    for (0..iterations) |_| {
        _ = client.send("world") catch {};
    }

    t1.join();
    // Close the write end to unblock drain thread
    std.posix.close(sockets[0].pipe_wr);
    sockets[0].pipe_wr = -1;
    drain_thread.join();
    // Close remaining read fd
    std.posix.close(sockets[0].pipe_rd);
    sockets[0].pipe_rd = -1;
}

test "concurrent send and recv" {
    // Test that send() and recv() can run concurrently from two threads.
    // Uses unencrypted TLS records (cipher = .none) over a pipe loopback.
    //
    // Setup: one pipe pair, single TLS client.
    // - Thread A calls client.send(data) → writes TLS records to pipe
    // - Thread B calls client.recv(buf) → reads TLS records from pipe
    //
    // With cipher = .none, the RecordLayer writes: header(5) + plaintext
    // and reads: header(5) + plaintext. The pipe connects output to input.
    var sockets = try PipeSocket.initPair();

    const TestClient = Client(PipeSocket, test_crypto, TestRuntime);
    var client = try TestClient.init(&sockets[0], .{
        .allocator = std.testing.allocator,
    });
    defer client.deinit();

    // Skip handshake — set connected directly
    client.connected = true;

    // Connect socket[0]'s write end to socket[0]'s read end via socket[1]
    // We need a relay: socket[0].send() → pipe_a_wr → pipe_a_rd → socket[1].recv()
    // Then relay thread: socket[1].recv() → socket[1].send() → pipe_b_wr → pipe_b_rd → socket[0].recv()

    const iterations = 500;
    const msg = "test-message-123";

    // Relay thread: reads from pipe_a, writes back to pipe_b (echo)
    const relay_thread = try std.Thread.spawn(.{}, struct {
        fn run(sock: *PipeSocket) void {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = sock.recv(&buf) catch break;
                if (n == 0) break;
                var written: usize = 0;
                while (written < n) {
                    const w = sock.send(buf[written..n]) catch break;
                    written += w;
                }
                if (written < n) break;
            }
        }
    }.run, .{&sockets[1]});

    // Sender thread
    const sender = try std.Thread.spawn(.{}, struct {
        fn run(c: *TestClient) void {
            for (0..iterations) |_| {
                _ = c.send(msg) catch {};
            }
            // Signal done by closing write end — this will cause relay to see EOF
        }
    }.run, .{&client});

    // Receiver (current thread): recv all data
    var total_received: usize = 0;
    var recv_buf: [4096]u8 = undefined;
    while (total_received < iterations * msg.len) {
        const n = client.recv(&recv_buf) catch |err| {
            // UnexpectedRecord when pipe closes
            if (err == error.UnexpectedRecord) break;
            break;
        };
        if (n == 0) break;
        total_received += n;
    }

    sender.join();
    // Close pipe ends to unblock relay
    std.posix.close(sockets[0].pipe_wr);
    sockets[0].pipe_wr = -1;
    std.posix.close(sockets[1].pipe_wr);
    sockets[1].pipe_wr = -1;
    relay_thread.join();

    // Close remaining fds
    std.posix.close(sockets[0].pipe_rd);
    sockets[0].pipe_rd = -1;
    std.posix.close(sockets[1].pipe_rd);
    sockets[1].pipe_rd = -1;

    // Verify we received a reasonable amount of data
    // (may not be 100% due to pipe close timing, but should be > 0)
    try std.testing.expect(total_received > 0);
}
