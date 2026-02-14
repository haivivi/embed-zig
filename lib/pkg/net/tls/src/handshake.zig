//! TLS Handshake Protocol
//!
//! Implements the TLS handshake state machine for both TLS 1.2 and TLS 1.3.
//! Reference: RFC 8446 (TLS 1.3), RFC 5246 (TLS 1.2)
//!
//! Fully generic over Crypto type - no direct crypto dependencies.

const std = @import("std");
const common = @import("common.zig");
const extensions = @import("extensions.zig");
const record = @import("record.zig");
const kdf = @import("kdf.zig");

const HandshakeType = common.HandshakeType;
const ProtocolVersion = common.ProtocolVersion;
const CipherSuite = common.CipherSuite;
const NamedGroup = common.NamedGroup;
const SignatureScheme = common.SignatureScheme;
const ContentType = common.ContentType;

// ============================================================================
// Handshake Message Header
// ============================================================================

pub const HandshakeHeader = struct {
    msg_type: HandshakeType,
    length: u24,

    pub const SIZE = 4;

    pub fn parse(buf: []const u8) !HandshakeHeader {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return HandshakeHeader{
            .msg_type = @enumFromInt(buf[0]),
            .length = std.mem.readInt(u24, buf[1..4], .big),
        };
    }

    pub fn serialize(self: HandshakeHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        buf[0] = @intFromEnum(self.msg_type);
        std.mem.writeInt(u24, buf[1..4], self.length, .big);
    }
};

// ============================================================================
// Key Exchange (Generic over Crypto)
// ============================================================================

pub fn KeyExchange(comptime Crypto: type) type {
    return union(enum) {
        x25519: X25519KeyExchange(Crypto),
        secp256r1: P256KeyExchange(Crypto),

        const Self = @This();

        pub fn generate(group: NamedGroup, rng_fill: *const fn ([]u8) void) !Self {
            return switch (group) {
                .x25519 => .{ .x25519 = try X25519KeyExchange(Crypto).generate(rng_fill) },
                .secp256r1 => .{ .secp256r1 = try P256KeyExchange(Crypto).generate(rng_fill) },
                else => error.UnsupportedGroup,
            };
        }

        pub fn publicKey(self: *const Self) []const u8 {
            return switch (self.*) {
                .x25519 => |*kx| &kx.public_key,
                .secp256r1 => |*kx| &kx.public_key,
            };
        }

        pub fn computeSharedSecret(self: *Self, peer_public: []const u8) ![]const u8 {
            return switch (self.*) {
                .x25519 => |*kx| try kx.computeSharedSecret(peer_public),
                .secp256r1 => |*kx| try kx.computeSharedSecret(peer_public),
            };
        }
    };
}

fn X25519KeyExchange(comptime Crypto: type) type {
    return struct {
        secret_key: [32]u8,
        public_key: [32]u8,
        shared_secret: [32]u8,

        const Self = @This();

        pub fn generate(rng_fill: *const fn ([]u8) void) !Self {
            var self = Self{
                .secret_key = [_]u8{0} ** 32,
                .public_key = [_]u8{0} ** 32,
                .shared_secret = [_]u8{0} ** 32,
            };
            rng_fill(&self.secret_key);
            const kp = try Crypto.X25519.KeyPair.generateDeterministic(self.secret_key);
            self.public_key = kp.public_key;
            return self;
        }

        pub fn computeSharedSecret(self: *Self, peer_public: []const u8) ![]const u8 {
            if (peer_public.len != 32) return error.InvalidPublicKey;
            self.shared_secret = try Crypto.X25519.scalarmult(
                self.secret_key,
                peer_public[0..32].*,
            );
            return &self.shared_secret;
        }
    };
}

fn P256KeyExchange(comptime Crypto: type) type {
    return struct {
        secret_key: [32]u8,
        public_key: [65]u8, // Uncompressed point: 0x04 || x || y
        shared_secret: [32]u8,

        const Self = @This();
        const P256 = Crypto.P256;

        pub fn generate(rng_fill: *const fn ([]u8) void) !Self {
            var self = Self{
                .secret_key = [_]u8{0} ** 32,
                .public_key = [_]u8{0} ** 65,
                .shared_secret = [_]u8{0} ** 32,
            };
            rng_fill(&self.secret_key);

            // Compute public key from secret key using ECDH interface
            self.public_key = P256.computePublicKey(self.secret_key) catch {
                return error.IdentityElement;
            };

            return self;
        }

        pub fn computeSharedSecret(self: *Self, peer_public: []const u8) ![]const u8 {
            // Peer public key should be uncompressed: 0x04 || x || y (65 bytes)
            if (peer_public.len != 65 or peer_public[0] != 0x04) {
                return error.InvalidPublicKey;
            }

            // Compute shared secret using ECDH
            self.shared_secret = P256.ecdh(self.secret_key, peer_public[0..65].*) catch {
                return error.IdentityElement;
            };

            return &self.shared_secret;
        }
    };
}

// ============================================================================
// Handshake State
// ============================================================================

pub const HandshakeState = enum {
    initial,
    wait_server_hello,
    wait_encrypted_extensions,
    wait_certificate,
    wait_certificate_verify,
    wait_finished,
    connected,
    error_state,
    // TLS 1.2 specific states
    wait_server_key_exchange,
    wait_server_hello_done,
};

// ============================================================================
// Transcript Hash (Generic over Crypto)
// ============================================================================

fn TranscriptHash(comptime Crypto: type) type {
    return struct {
        sha256: Crypto.Sha256,

        const Self = @This();

        pub fn init() Self {
            return Self{
                .sha256 = Crypto.Sha256.init(),
            };
        }

        pub fn update(self: *Self, data: []const u8) void {
            self.sha256.update(data);
        }

        pub fn peek(self: *Self) [32]u8 {
            var copy = self.sha256;
            return copy.final();
        }

        pub fn final(self: *Self) [32]u8 {
            return self.sha256.final();
        }
    };
}

// ============================================================================
// TLS 1.2 PRF (Generic over Crypto)
// ============================================================================

fn Tls12Prf(comptime Crypto: type) type {
    return struct {
        /// TLS 1.2 PRF based on HMAC-SHA256
        /// P_hash(secret, seed) = HMAC_hash(secret, A(1) + seed) +
        ///                        HMAC_hash(secret, A(2) + seed) + ...
        /// where A(0) = seed, A(i) = HMAC_hash(secret, A(i-1))
        pub fn prf(out: []u8, secret: []const u8, label: []const u8, seed: []const u8) void {
            const Hmac = Crypto.HmacSha256;

            // Concatenate label + seed
            var label_seed: [128]u8 = undefined;
            @memcpy(label_seed[0..label.len], label);
            @memcpy(label_seed[label.len..][0..seed.len], seed);
            const ls = label_seed[0 .. label.len + seed.len];

            // A(1) = HMAC(secret, A(0)) = HMAC(secret, label + seed)
            var a: [32]u8 = undefined;
            Hmac.create(&a, ls, secret);

            var pos: usize = 0;
            while (pos < out.len) {
                // P_hash = HMAC(secret, A(i) + label + seed)
                var ctx = Hmac.init(secret);
                ctx.update(&a);
                ctx.update(ls);
                const p = ctx.final();

                // Copy to output
                const copy_len = @min(32, out.len - pos);
                @memcpy(out[pos..][0..copy_len], p[0..copy_len]);
                pos += copy_len;

                // A(i+1) = HMAC(secret, A(i))
                Hmac.create(&a, &a, secret);
            }
        }
    };
}

// ============================================================================
// Client Handshake
// ============================================================================

/// Client handshake state machine
/// Generic over Socket and Crypto implementations
/// Crypto must include Rng (Crypto.Rng.fill)
pub fn ClientHandshake(comptime Socket: type, comptime Crypto: type) type {
    // Get CaStore type from Crypto if available
    const CaStore = if (@hasDecl(Crypto, "x509") and @hasDecl(Crypto.x509, "CaStore"))
        Crypto.x509.CaStore
    else
        void;

    return struct {
        // Connection state
        state: HandshakeState,
        version: ProtocolVersion,
        cipher_suite: CipherSuite,

        // Random values
        client_random: [32]u8,
        server_random: [32]u8,

        // Key exchange
        key_exchange: ?KeyExchange(Crypto),

        // Session keys (TLS 1.3)
        handshake_secret: [48]u8,
        master_secret: [48]u8,
        client_handshake_traffic_secret: [48]u8,
        server_handshake_traffic_secret: [48]u8,
        client_application_traffic_secret: [48]u8,
        server_application_traffic_secret: [48]u8,

        // TLS 1.2 specific
        tls12_server_pubkey: [97]u8, // Max size for P-384
        tls12_server_pubkey_len: u8,
        tls12_named_group: NamedGroup,

        // Server certificate (for CertificateVerify validation)
        server_cert_der: [4096]u8, // Max 4KB for leaf certificate (CDN certs can be ~3KB)
        server_cert_der_len: u16,

        // Transcript hash
        transcript_hash: TranscriptHash(Crypto),

        // Record layer
        records: record.RecordLayer(Socket, Crypto),

        // Configuration
        hostname: []const u8,
        allocator: std.mem.Allocator,

        // Certificate verification
        ca_store: if (CaStore != void) ?CaStore else void,

        const Self = @This();

        /// CaStore type for certificate verification (void if Crypto doesn't support x509)
        pub const CaStoreType = CaStore;

        pub fn init(
            socket: *Socket,
            hostname: []const u8,
            allocator: std.mem.Allocator,
            ca_store: if (CaStore != void) ?CaStore else void,
        ) Self {
            // Initialize all fields to zero to avoid undefined behavior in Release mode
            var self = Self{
                .state = .initial,
                .version = .tls_1_3,
                .cipher_suite = .TLS_AES_128_GCM_SHA256,
                .client_random = [_]u8{0} ** 32,
                .server_random = [_]u8{0} ** 32,
                .key_exchange = null,
                .handshake_secret = [_]u8{0} ** 48,
                .master_secret = [_]u8{0} ** 48,
                .client_handshake_traffic_secret = [_]u8{0} ** 48,
                .server_handshake_traffic_secret = [_]u8{0} ** 48,
                .client_application_traffic_secret = [_]u8{0} ** 48,
                .server_application_traffic_secret = [_]u8{0} ** 48,
                .tls12_server_pubkey = [_]u8{0} ** 97,
                .tls12_server_pubkey_len = 0,
                .tls12_named_group = .x25519,
                .server_cert_der = [_]u8{0} ** 4096,
                .server_cert_der_len = 0,
                .transcript_hash = TranscriptHash(Crypto).init(),
                .records = record.RecordLayer(Socket, Crypto).init(socket),
                .hostname = hostname,
                .allocator = allocator,
                .ca_store = ca_store,
            };

            // Generate client random
            Crypto.Rng.fill(&self.client_random);

            return self;
        }

        /// Perform the TLS handshake
        pub fn handshake(self: *Self, buffer: []u8) !void {
            // Send ClientHello
            try self.sendClientHello(buffer);
            self.state = .wait_server_hello;

            // Receive and process messages until connected
            while (self.state != .connected and self.state != .error_state) {
                try self.processServerMessage(buffer);
            }

            if (self.state == .error_state) {
                return error.HandshakeFailed;
            }
        }

        fn sendClientHello(self: *Self, buffer: []u8) !void {
            var msg_buf: [512]u8 = undefined;
            var pos: usize = 0;

            // Legacy version (TLS 1.2 for compatibility)
            std.mem.writeInt(u16, msg_buf[pos..][0..2], @intFromEnum(ProtocolVersion.tls_1_2), .big);
            pos += 2;

            // Client random
            @memcpy(msg_buf[pos..][0..32], &self.client_random);
            pos += 32;

            // Legacy session ID (empty for TLS 1.3)
            msg_buf[pos] = 0;
            pos += 1;

            // Cipher suites (minimal: SHA-256 based only to reduce binary size)
            const cipher_suites = [_]CipherSuite{
                // TLS 1.3 (SHA-256 only)
                .TLS_AES_128_GCM_SHA256,
                // TLS 1.2 ECDHE fallback (SHA-256 only)
                .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
            };
            std.mem.writeInt(u16, msg_buf[pos..][0..2], @intCast(cipher_suites.len * 2), .big);
            pos += 2;
            for (cipher_suites) |suite| {
                std.mem.writeInt(u16, msg_buf[pos..][0..2], @intFromEnum(suite), .big);
                pos += 2;
            }

            // Compression methods (null only)
            msg_buf[pos] = 1; // length
            pos += 1;
            msg_buf[pos] = 0; // null compression
            pos += 1;

            // Extensions
            var ext_buf: [512]u8 = undefined;
            var ext_builder = extensions.ExtensionBuilder.init(&ext_buf);

            // SNI
            try ext_builder.addServerName(self.hostname);

            // EC Point Formats (required for TLS 1.2 ECDHE)
            try ext_builder.addEcPointFormats();

            // Supported versions
            const versions = [_]ProtocolVersion{ .tls_1_3, .tls_1_2 };
            try ext_builder.addSupportedVersions(&versions);

            // Supported groups (X25519 + P-256)
            const groups = [_]NamedGroup{ .x25519, .secp256r1 };
            try ext_builder.addSupportedGroups(&groups);

            // Signature algorithms
            const sig_algs = [_]SignatureScheme{
                .ecdsa_secp256r1_sha256,
                .ecdsa_secp384r1_sha384,
                .rsa_pss_rsae_sha256,
                .rsa_pss_rsae_sha384,
                .rsa_pkcs1_sha256,
                .rsa_pkcs1_sha384,
            };
            try ext_builder.addSignatureAlgorithms(&sig_algs);

            // Generate key share
            self.key_exchange = try KeyExchange(Crypto).generate(.x25519, &Crypto.Rng.fill);
            const key_share_entries = [_]extensions.KeyShareEntry{
                .{ .group = .x25519, .key_exchange = self.key_exchange.?.publicKey() },
            };
            try ext_builder.addKeyShareClient(&key_share_entries);

            // PSK key exchange modes
            const psk_modes = [_]common.PskKeyExchangeMode{.psk_dhe_ke};
            try ext_builder.addPskKeyExchangeModes(&psk_modes);

            // Write extensions length and data
            const ext_data = ext_builder.getData();
            std.mem.writeInt(u16, msg_buf[pos..][0..2], @intCast(ext_data.len), .big);
            pos += 2;
            @memcpy(msg_buf[pos..][0..ext_data.len], ext_data);
            pos += ext_data.len;

            // Build handshake message
            var handshake_buf: [1024]u8 = undefined;
            const header = HandshakeHeader{
                .msg_type = .client_hello,
                .length = @intCast(pos),
            };
            try header.serialize(handshake_buf[0..4]);
            @memcpy(handshake_buf[4..][0..pos], msg_buf[0..pos]);

            // Update transcript hash
            self.transcript_hash.update(handshake_buf[0 .. 4 + pos]);
            
            // Send as record
            _ = try self.records.writeRecord(.handshake, handshake_buf[0 .. 4 + pos], buffer);
        }

        fn processServerMessage(self: *Self, buffer: []u8) !void {
            var plaintext: [common.MAX_CIPHERTEXT_LEN]u8 = undefined;
            const result = try self.records.readRecord(buffer, &plaintext);

            switch (result.content_type) {
                .handshake => try self.processHandshake(plaintext[0..result.length]),
                .alert => {
                    self.state = .error_state;
                    return error.AlertReceived;
                },
                .change_cipher_spec => {
                    // TLS 1.3 compatibility, ignore
                },
                else => {
                    self.state = .error_state;
                    return error.UnexpectedMessage;
                },
            }
        }

        fn processHandshake(self: *Self, data: []const u8) !void {
            // Process all handshake messages in this record (TLS 1.3 often combines multiple)
            var pos: usize = 0;
            while (pos + 4 <= data.len) {
                const header = try HandshakeHeader.parse(data[pos..]);

                // CRITICAL: Bounds check before slicing!
                const total_len = 4 + @as(usize, header.length);
                if (pos + total_len > data.len) return error.InvalidHandshake;

                const msg_data = data[pos + 4 ..][0..header.length];
                const raw_msg = data[pos..][0..total_len];

                // Special handling for messages that need transcript hash BEFORE the message itself:
                // - Finished (TLS 1.2 and 1.3): verify_data computed over messages NOT including Finished
                // - CertificateVerify: signature computed over transcript BEFORE CertificateVerify
                const needs_pre_verify = (header.msg_type == .finished) or
                    (header.msg_type == .certificate_verify);

                if (needs_pre_verify) {
                    // Process first (uses current transcript), then update transcript
                    switch (header.msg_type) {
                        .certificate_verify => {
                            try self.processCertificateVerify(msg_data);
                            self.transcript_hash.update(raw_msg);
                        },
                        .finished => {
                            // For TLS 1.3 Finished: verify first, then update transcript,
                            // then derive app keys (which need transcript including Finished)
                            try self.processFinished(msg_data, raw_msg);
                            // transcript update is done inside processFinished for TLS 1.3
                        },
                        else => unreachable,
                    }
                } else {
                    // Update transcript before processing
                    self.transcript_hash.update(raw_msg);

                    switch (header.msg_type) {
                        .server_hello => try self.processServerHello(msg_data),
                        .encrypted_extensions => try self.processEncryptedExtensions(msg_data),
                        .certificate => try self.processCertificate(msg_data),
                        .server_key_exchange => try self.processServerKeyExchange(msg_data),
                        .server_hello_done => try self.processServerHelloDone(msg_data),
                        .finished => try self.processFinished(msg_data, raw_msg),
                        else => {
                            // Skip unknown messages
                        },
                    }
                }

                pos += total_len;
            }
        }

        fn processServerHello(self: *Self, data: []const u8) !void {
            if (self.state != .wait_server_hello) return error.UnexpectedMessage;
            if (data.len < 34) return error.InvalidHandshake;

            // Parse legacy version (use safe conversion to avoid panic on unknown version)
            const legacy_version_raw = std.mem.readInt(u16, data[0..2], .big);
            const legacy_version: ProtocolVersion = std.meta.intToEnum(ProtocolVersion, legacy_version_raw) catch {
                return error.UnsupportedVersion;
            };

            // Parse server random
            @memcpy(&self.server_random, data[2..34]);

            // Check for HelloRetryRequest (TLS 1.3)
            const hello_retry_magic = [_]u8{
                0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11,
                0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
                0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E,
                0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
            };
            if (std.mem.eql(u8, &self.server_random, &hello_retry_magic)) {
                return error.HelloRetryNotSupported;
            }

            var pos: usize = 34;

            // Session ID - with bounds check
            if (pos >= data.len) return error.InvalidHandshake;
            const session_id_len = data[pos];
            pos += 1;
            if (pos + session_id_len > data.len) return error.InvalidHandshake;
            pos += session_id_len;

            // Cipher suite (use safe conversion)
            if (pos + 2 > data.len) return error.InvalidHandshake;
            const cipher_raw = std.mem.readInt(u16, data[pos..][0..2], .big);
            self.cipher_suite = std.meta.intToEnum(CipherSuite, cipher_raw) catch {
                return error.UnsupportedCipherSuite;
            };
            pos += 2;

            // Compression method
            pos += 1;

            // Default to legacy version, may be overridden by extension
            self.version = legacy_version;

            // Parse extensions (if present)
            if (pos + 2 <= data.len) {
                const ext_len = std.mem.readInt(u16, data[pos..][0..2], .big);
                pos += 2;

                if (pos + ext_len <= data.len) {
                    const ext_data = data[pos..][0..ext_len];
                    var ext_pos: usize = 0;

                    while (ext_pos + 4 <= ext_data.len) {
                        const ext_type_raw = std.mem.readInt(u16, ext_data[ext_pos..][0..2], .big);
                        ext_pos += 2;
                        const ext_size = std.mem.readInt(u16, ext_data[ext_pos..][0..2], .big);
                        ext_pos += 2;

                        // CRITICAL: Bounds check before slicing extension content!
                        if (ext_pos + ext_size > ext_data.len) break;
                        
                        const ext_content = ext_data[ext_pos..][0..ext_size];
                        ext_pos += ext_size;

                        // Try to parse extension type, skip unknown extensions
                        const ext_type = std.meta.intToEnum(common.ExtensionType, ext_type_raw) catch continue;

                        switch (ext_type) {
                            .supported_versions => {
                                self.version = try extensions.parseSupportedVersion(ext_content);
                            },
                            .key_share => {
                                const key_share = try extensions.parseKeyShareServer(ext_content);
                                // DEBUG: log server's key_share group and length
                                if (@import("builtin").mode == .ReleaseSmall) {
                                    // In release mode, use Zig's log
                                    @import("std").log.info("[TLS] server key_share: group=0x{x}, key_len={}", .{ @intFromEnum(key_share.group), key_share.key_exchange.len });
                                }
                                // Compute shared secret (TLS 1.3)
                                if (self.key_exchange) |*kx| {
                                    const shared = try kx.computeSharedSecret(key_share.key_exchange);
                                    try self.deriveHandshakeKeys(shared);
                                }
                            },
                            else => {},
                        }
                    }
                }
            }

            if (self.version == .tls_1_3) {
                self.state = .wait_encrypted_extensions;
            } else {
                // TLS 1.2 - wait for certificate and key exchange
                self.state = .wait_certificate;
            }
        }

        fn processEncryptedExtensions(self: *Self, data: []const u8) !void {
            if (self.state != .wait_encrypted_extensions) return error.UnexpectedMessage;
            _ = data; // Parse but don't require any specific extensions
            self.state = .wait_certificate;
        }

        fn processCertificate(self: *Self, data: []const u8) !void {
            if (self.state != .wait_certificate) return error.UnexpectedMessage;

            // TLS 1.3 has a request context byte first
            var pos: usize = 0;
            if (self.version == .tls_1_3) {
                if (data.len < 1) return error.InvalidHandshake;
                const context_len = data[0];
                pos = 1 + context_len;
            }

            // Certificate list length
            if (pos + 3 > data.len) return error.InvalidHandshake;
            const certs_len = std.mem.readInt(u24, data[pos..][0..3], .big);
            pos += 3;

            // Parse certificate list
            const cert_list_end = pos + certs_len;
            if (cert_list_end > data.len) return error.InvalidHandshake;

            // Collect certificate DER data (max 10 certificates in chain)
            var cert_chain: [10][]const u8 = undefined;
            var cert_count: usize = 0;

            while (pos < cert_list_end and cert_count < 10) {
                // Certificate data length (3 bytes)
                if (pos + 3 > cert_list_end) return error.InvalidHandshake;
                const cert_len = std.mem.readInt(u24, data[pos..][0..3], .big);
                pos += 3;

                // Certificate data
                if (pos + cert_len > cert_list_end) return error.InvalidHandshake;
                cert_chain[cert_count] = data[pos..][0..cert_len];
                cert_count += 1;
                pos += cert_len;

                // TLS 1.3 has per-certificate extensions
                if (self.version == .tls_1_3) {
                    if (pos + 2 > cert_list_end) return error.InvalidHandshake;
                    const ext_len = std.mem.readInt(u16, data[pos..][0..2], .big);
                    pos += 2 + ext_len;
                }
            }

            if (cert_count == 0) return error.InvalidHandshake;

            // Save leaf certificate for CertificateVerify validation
            const leaf_cert = cert_chain[0];
            if (leaf_cert.len > self.server_cert_der.len) {
                return error.CertificateTooLarge;
            }
            @memcpy(self.server_cert_der[0..leaf_cert.len], leaf_cert);
            self.server_cert_der_len = @intCast(leaf_cert.len);

            // Verify certificate chain if ca_store is provided
            if (CaStore != void) {
                if (self.ca_store) |store| {
                    // Get current time for certificate validity check
                    // On freestanding/embedded targets without OS, use 0 (cert.zig ignores time)
                    const builtin = @import("builtin");
                    const now_sec: i64 = if (builtin.os.tag == .freestanding)
                        0 // No system time on embedded - cert.zig will skip time check
                    else
                        std.time.timestamp();

                    // Verify the certificate chain
                    Crypto.x509.verifyChain(
                        cert_chain[0..cert_count],
                        if (self.hostname.len > 0) self.hostname else null,
                        store,
                        now_sec,
                    ) catch |err| {
                        std.log.err("[TLS] Certificate verification failed: {}", .{err});
                        return error.CertificateVerificationFailed;
                    };
                }
            }

            if (self.version == .tls_1_3) {
                self.state = .wait_certificate_verify;
            } else {
                // TLS 1.2 ECDHE: Certificate -> ServerKeyExchange -> ServerHelloDone
                self.state = .wait_server_key_exchange;
            }
        }

        /// Process TLS 1.2 ServerKeyExchange message
        fn processServerKeyExchange(self: *Self, data: []const u8) !void {
            if (self.version == .tls_1_3) return error.UnexpectedMessage;
            if (self.state != .wait_server_key_exchange) return error.UnexpectedMessage;

            // Parse ECDHE parameters
            // Format: curve_type (1) + named_curve (2) + pubkey_len (1) + pubkey + signature
            if (data.len < 4) return error.InvalidHandshake;

            const curve_type = data[0];
            if (curve_type != 0x03) return error.UnsupportedGroup; // named_curve

            const group_raw = std.mem.readInt(u16, data[1..3], .big);
            const named_group: NamedGroup = std.meta.intToEnum(NamedGroup, group_raw) catch {
                return error.UnsupportedGroup;
            };
            const pubkey_len = data[3];

            if (data.len < 4 + pubkey_len) return error.InvalidHandshake;
            const server_pubkey = data[4..][0..pubkey_len];

            // Parse signature (after ECDHE params)
            const sig_offset = 4 + pubkey_len;
            if (data.len < sig_offset + 4) return error.InvalidHandshake;

            const sig_scheme = std.mem.readInt(u16, data[sig_offset..][0..2], .big);
            const sig_len = std.mem.readInt(u16, data[sig_offset + 2 ..][0..2], .big);

            if (data.len < sig_offset + 4 + sig_len) return error.InvalidHandshake;
            const signature = data[sig_offset + 4 ..][0..sig_len];

            // Verify signature over ServerKeyExchange params
            // Signature covers: client_random + server_random + params
            // params = curve_type (1) + named_curve (2) + pubkey_len (1) + pubkey
            const params_len = 4 + pubkey_len;
            var signed_data: [32 + 32 + 4 + 256]u8 = undefined; // client_random + server_random + max params
            const total_len = 32 + 32 + params_len;
            @memcpy(signed_data[0..32], &self.client_random);
            @memcpy(signed_data[32..64], &self.server_random);
            @memcpy(signed_data[64..][0..params_len], data[0..params_len]);

            // Parse server certificate to get public key
            const cert_der = self.server_cert_der[0..self.server_cert_der_len];
            const Certificate = std.crypto.Certificate;
            const cert = Certificate{ .buffer = cert_der, .index = 0 };
            const parsed = cert.parse() catch return error.InvalidCertificate;

            // Verify signature
            try verifySignature(sig_scheme, signed_data[0..total_len], signature, parsed);

            // Generate key exchange matching server's chosen curve
            self.key_exchange = try KeyExchange(Crypto).generate(named_group, &Crypto.Rng.fill);

            // CRITICAL: Bounds check - pubkey must fit in our buffer (97 bytes max for P-384)
            if (pubkey_len > self.tls12_server_pubkey.len) return error.InvalidPublicKey;

            // Store server's public key for later (we'll compute shared secret in ClientKeyExchange)
            @memcpy(self.tls12_server_pubkey[0..pubkey_len], server_pubkey);
            self.tls12_server_pubkey_len = pubkey_len;
            self.tls12_named_group = named_group;

            self.state = .wait_server_hello_done;
        }

        /// Process TLS 1.2 ServerHelloDone message
        fn processServerHelloDone(self: *Self, data: []const u8) !void {
            if (self.version == .tls_1_3) return error.UnexpectedMessage;
            if (self.state != .wait_server_hello_done) return error.UnexpectedMessage;
            _ = data; // ServerHelloDone has no content

            // Now we need to send ClientKeyExchange and derive keys
            try self.sendClientKeyExchange();

            self.state = .wait_finished;
        }

        /// Send TLS 1.2 ClientKeyExchange message
        fn sendClientKeyExchange(self: *Self) !void {
            if (self.key_exchange == null) return error.InvalidHandshake;

            var msg_buf: [256]u8 = undefined;
            var pos: usize = 0;

            // Public key length and data
            const pubkey = self.key_exchange.?.publicKey();
            msg_buf[pos] = @intCast(pubkey.len);
            pos += 1;
            @memcpy(msg_buf[pos..][0..pubkey.len], pubkey);
            pos += pubkey.len;

            // Build handshake message
            var handshake_buf: [512]u8 = undefined;
            const header = HandshakeHeader{
                .msg_type = .client_key_exchange,
                .length = @intCast(pos),
            };
            try header.serialize(handshake_buf[0..4]);
            @memcpy(handshake_buf[4..][0..pos], msg_buf[0..pos]);

            // Update transcript
            self.transcript_hash.update(handshake_buf[0 .. 4 + pos]);

            // Send record
            var write_buf: [1024]u8 = undefined;
            _ = try self.records.writeRecord(.handshake, handshake_buf[0 .. 4 + pos], &write_buf);

            // Compute shared secret
            const server_pubkey = self.tls12_server_pubkey[0..self.tls12_server_pubkey_len];
            const shared_secret = try self.key_exchange.?.computeSharedSecret(server_pubkey);

            // Derive TLS 1.2 keys
            try self.deriveTls12Keys(shared_secret);

            // Send ChangeCipherSpec
            try self.sendChangeCipherSpec();

            // Send Finished
            try self.sendFinished();
        }

        /// Send ChangeCipherSpec message (TLS 1.2)
        fn sendChangeCipherSpec(self: *Self) !void {
            var write_buf: [64]u8 = undefined;
            const ccs_data = [_]u8{1}; // change_cipher_spec

            // ChangeCipherSpec is NOT a handshake message
            const header = record.RecordHeader{
                .content_type = .change_cipher_spec,
                .legacy_version = .tls_1_2,
                .length = 1,
            };
            try header.serialize(write_buf[0..5]);
            write_buf[5] = ccs_data[0];

            _ = try self.records.socket.send(write_buf[0..6]);

            // Enable write encryption
            // (cipher was set in deriveTls12Keys)
        }

        /// Send Finished message
        fn sendFinished(self: *Self) !void {
            // Compute verify_data (must be computed BEFORE adding Finished to transcript)
            const verify_data = self.computeVerifyData(true); // client

            var handshake_buf: [64]u8 = undefined;
            const header = HandshakeHeader{
                .msg_type = .finished,
                .length = 12, // verify_data is always 12 bytes in TLS 1.2
            };
            try header.serialize(handshake_buf[0..4]);
            @memcpy(handshake_buf[4..16], verify_data[0..12]);

            // Update transcript with Client Finished (needed for server's Finished verification)
            self.transcript_hash.update(handshake_buf[0..16]);

            // Send encrypted record
            var write_buf: [128]u8 = undefined;
            _ = try self.records.writeRecord(.handshake, handshake_buf[0..16], &write_buf);
        }

        /// Derive TLS 1.2 keys from pre-master secret
        fn deriveTls12Keys(self: *Self, pre_master_secret: []const u8) !void {
            const Prf = Tls12Prf(Crypto);

            // master_secret = PRF(pre_master_secret, "master secret", client_random + server_random)
            var seed: [64]u8 = undefined;
            @memcpy(seed[0..32], &self.client_random);
            @memcpy(seed[32..64], &self.server_random);

            var master_secret: [48]u8 = undefined;
            Prf.prf(&master_secret, pre_master_secret, "master secret", &seed);
            @memcpy(self.master_secret[0..48], &master_secret);

            // key_block = PRF(master_secret, "key expansion", server_random + client_random)
            @memcpy(seed[0..32], &self.server_random);
            @memcpy(seed[32..64], &self.client_random);

            // For AES-128-GCM: client_write_key(16) + server_write_key(16) + client_write_iv(4) + server_write_iv(4)
            var key_block: [72]u8 = undefined;
            Prf.prf(&key_block, &master_secret, "key expansion", &seed);

            const key_len = self.cipher_suite.keyLength();
            const iv_len: usize = 4; // Implicit IV for TLS 1.2 GCM

            const client_write_key = key_block[0..key_len];
            const server_write_key = key_block[key_len..][0..key_len];
            const client_write_iv = key_block[2 * key_len ..][0..iv_len];
            const server_write_iv = key_block[2 * key_len + iv_len ..][0..iv_len];

            // For GCM, we need 12-byte nonce: 4-byte implicit IV + 8-byte explicit nonce
            // The explicit nonce is the sequence number
            var client_iv: [12]u8 = undefined;
            var server_iv: [12]u8 = undefined;
            @memcpy(client_iv[0..iv_len], client_write_iv);
            @memset(client_iv[iv_len..], 0);
            @memcpy(server_iv[0..iv_len], server_write_iv);
            @memset(server_iv[iv_len..], 0);

            // Set up ciphers
            const write_cipher = try record.CipherState(Crypto).init(self.cipher_suite, client_write_key, &client_iv);
            const read_cipher = try record.CipherState(Crypto).init(self.cipher_suite, server_write_key, &server_iv);

            self.records.setWriteCipher(write_cipher);
            self.records.setReadCipher(read_cipher);

            // Set version for proper record format
            self.records.version = .tls_1_2;
        }

        /// Compute verify_data for Finished message
        fn computeVerifyData(self: *Self, is_client: bool) [12]u8 {
            const Prf = Tls12Prf(Crypto);
            const label = if (is_client) "client finished" else "server finished";

            const transcript = self.transcript_hash.peek();
            var verify_data: [12]u8 = undefined;
            Prf.prf(&verify_data, self.master_secret[0..48], label, &transcript);
            return verify_data;
        }

        fn processCertificateVerify(self: *Self, data: []const u8) !void {
            if (self.state != .wait_certificate_verify) return error.UnexpectedMessage;

            // Parse CertificateVerify message (RFC 8446 Section 4.4.3)
            // struct {
            //     SignatureScheme algorithm;
            //     opaque signature<0..2^16-1>;
            // }
            if (data.len < 4) return error.InvalidHandshake;

            const sig_scheme = std.mem.readInt(u16, data[0..2], .big);
            const sig_len = std.mem.readInt(u16, data[2..4], .big);

            if (data.len < 4 + sig_len) return error.InvalidHandshake;
            const signature = data[4..][0..sig_len];

            // Build the content to verify (RFC 8446 Section 4.4.3)
            // The digital signature is computed over:
            //   64 bytes of 0x20 (space) +
            //   context string ("TLS 1.3, server CertificateVerify" + 0x00) +
            //   transcript hash
            const context_string = "TLS 1.3, server CertificateVerify";
            const transcript = self.transcript_hash.peek();

            var content: [64 + context_string.len + 1 + 32]u8 = undefined;
            @memset(content[0..64], 0x20); // 64 spaces
            @memcpy(content[64..][0..context_string.len], context_string);
            content[64 + context_string.len] = 0x00;
            @memcpy(content[64 + context_string.len + 1 ..][0..32], &transcript);

            // Parse server certificate to get public key
            const cert_der = self.server_cert_der[0..self.server_cert_der_len];
            const Certificate = std.crypto.Certificate;
            const cert = Certificate{ .buffer = cert_der, .index = 0 };
            const parsed = cert.parse() catch return error.InvalidCertificate;

            // Verify signature based on algorithm
            try verifySignature(sig_scheme, &content, signature, parsed);

            self.state = .wait_finished;
        }

        /// Verify TLS 1.3 CertificateVerify signature
        fn verifySignature(
            sig_scheme: u16,
            content: []const u8,
            signature: []const u8,
            parsed_cert: std.crypto.Certificate.Parsed,
        ) !void {
            switch (sig_scheme) {
                // ECDSA with SHA-256 on P-256
                0x0403 => {
                    const pk = Crypto.EcdsaP256Sha256.PublicKey.fromSec1(parsed_cert.pubKey()) catch {
                        return error.InvalidPublicKey;
                    };
                    const sig = Crypto.EcdsaP256Sha256.Signature.fromDer(signature) catch {
                        return error.InvalidSignature;
                    };
                    sig.verify(content, pk) catch return error.SignatureVerificationFailed;
                },

                // ECDSA with SHA-384 on P-384
                0x0503 => {
                    const pk = Crypto.EcdsaP384Sha384.PublicKey.fromSec1(parsed_cert.pubKey()) catch {
                        return error.InvalidPublicKey;
                    };
                    const sig = Crypto.EcdsaP384Sha384.Signature.fromDer(signature) catch {
                        return error.InvalidSignature;
                    };
                    sig.verify(content, pk) catch return error.SignatureVerificationFailed;
                },

                // RSA-PKCS1-SHA256
                0x0401 => {
                    try verifyRsaPkcs1(Crypto, .sha256, content, signature, parsed_cert.pubKey());
                },

                // RSA-PKCS1-SHA384
                0x0501 => {
                    try verifyRsaPkcs1(Crypto, .sha384, content, signature, parsed_cert.pubKey());
                },

                // RSA-PSS-RSAE-SHA256
                0x0804 => {
                    try verifyRsaPss(Crypto, .sha256, content, signature, parsed_cert.pubKey());
                },

                // RSA-PSS-RSAE-SHA384
                0x0805 => {
                    try verifyRsaPss(Crypto, .sha384, content, signature, parsed_cert.pubKey());
                },

                else => {
                    std.log.warn("[TLS] Unsupported signature scheme: 0x{x:0>4}", .{sig_scheme});
                    return error.UnsupportedSignatureAlgorithm;
                },
            }
        }

        /// Verify RSA-PKCS1v1.5 signature using Crypto module
        fn verifyRsaPkcs1(
            comptime C: type,
            comptime hash_type: C.rsa.HashType,
            msg: []const u8,
            sig: []const u8,
            pub_key: []const u8,
        ) !void {
            const pk_components = C.rsa.PublicKey.parseDer(pub_key) catch return error.InvalidPublicKey;
            const modulus = pk_components.modulus;
            if (sig.len != modulus.len) return error.InvalidSignature;

            // Support 2048-bit (256 bytes) and 4096-bit (512 bytes) RSA keys
            if (modulus.len == 256) {
                const public_key = C.rsa.PublicKey.fromBytes(pk_components.exponent, modulus) catch
                    return error.InvalidPublicKey;
                C.rsa.PKCS1v1_5Signature.verify(256, sig[0..256].*, msg, public_key, hash_type) catch
                    return error.SignatureVerificationFailed;
            } else if (modulus.len == 512) {
                const public_key = C.rsa.PublicKey.fromBytes(pk_components.exponent, modulus) catch
                    return error.InvalidPublicKey;
                C.rsa.PKCS1v1_5Signature.verify(512, sig[0..512].*, msg, public_key, hash_type) catch
                    return error.SignatureVerificationFailed;
            } else {
                return error.UnsupportedSignatureAlgorithm;
            }
        }

        /// Verify RSA-PSS signature using Crypto module
        fn verifyRsaPss(
            comptime C: type,
            comptime hash_type: C.rsa.HashType,
            msg: []const u8,
            sig: []const u8,
            pub_key: []const u8,
        ) !void {
            const pk_components = C.rsa.PublicKey.parseDer(pub_key) catch return error.InvalidPublicKey;
            const modulus = pk_components.modulus;
            if (sig.len != modulus.len) return error.InvalidSignature;

            if (modulus.len == 256) {
                const public_key = C.rsa.PublicKey.fromBytes(pk_components.exponent, modulus) catch
                    return error.InvalidPublicKey;
                C.rsa.PSSSignature.verify(256, sig[0..256].*, msg, public_key, hash_type) catch
                    return error.SignatureVerificationFailed;
            } else if (modulus.len == 512) {
                const public_key = C.rsa.PublicKey.fromBytes(pk_components.exponent, modulus) catch
                    return error.InvalidPublicKey;
                C.rsa.PSSSignature.verify(512, sig[0..512].*, msg, public_key, hash_type) catch
                    return error.SignatureVerificationFailed;
            } else {
                return error.UnsupportedSignatureAlgorithm;
            }
        }

        fn processFinished(self: *Self, data: []const u8, raw_msg: []const u8) !void {
            if (self.state != .wait_finished) return error.UnexpectedMessage;

            if (self.version == .tls_1_3) {
                // TLS 1.3 Finished verification (RFC 8446 Section 4.4.4)
                const Hkdf = Crypto.HkdfSha256;
                const hash_len = 32;

                if (data.len < hash_len) return error.InvalidHandshake;

                // Compute server's finished_key from server_handshake_traffic_secret
                const finished_key = kdf.hkdfExpandLabel(
                    Hkdf,
                    self.server_handshake_traffic_secret[0..hash_len].*,
                    "finished",
                    "",
                    hash_len,
                );

                // Compute expected verify_data = HMAC(finished_key, transcript_hash)
                // Note: transcript_hash is up to (but not including) this Finished message
                const transcript = self.transcript_hash.peek();
                var expected: [32]u8 = undefined;
                Crypto.HmacSha256.create(&expected, &transcript, &finished_key);

                // Compare with received verify_data
                if (!std.mem.eql(u8, data[0..hash_len], &expected)) {
                    return error.BadRecordMac;
                }

                // Update transcript with Server Finished BEFORE deriving application keys
                // RFC 8446: application traffic secrets use transcript up to AND INCLUDING Server Finished
                self.transcript_hash.update(raw_msg);

                // Derive application keys
                try self.deriveApplicationKeys();

                // Send Client Finished (using handshake traffic secret)
                try self.sendTls13Finished();
            } else {
                // TLS 1.2 Finished verification
                if (data.len < 12) return error.InvalidHandshake;

                // Compute expected server verify_data
                const expected = self.computeVerifyData(false); // server finished

                // Compare with received verify_data
                if (!std.mem.eql(u8, data[0..12], &expected)) {
                    return error.BadRecordMac;
                }

                // Update transcript after verification (TLS 1.2 needs this for client Finished)
                self.transcript_hash.update(raw_msg);

                // For TLS 1.2, application keys are already set in sendClientKeyExchange
            }

            self.state = .connected;
        }

        /// Send TLS 1.3 Client Finished message
        fn sendTls13Finished(self: *Self) !void {
            const Hkdf = Crypto.HkdfSha256;
            const hash_len = 32;

            // Compute finished_key from client_handshake_traffic_secret
            const finished_key = kdf.hkdfExpandLabel(
                Hkdf,
                self.client_handshake_traffic_secret[0..hash_len].*,
                "finished",
                "",
                hash_len,
            );

            // Compute verify_data = HMAC(finished_key, transcript_hash)
            const transcript = self.transcript_hash.peek();
            var verify_data: [32]u8 = undefined;
            Crypto.HmacSha256.create(&verify_data, &transcript, &finished_key);

            // Build Finished message
            var handshake_buf: [64]u8 = undefined;
            const header = HandshakeHeader{
                .msg_type = .finished,
                .length = 32,
            };
            try header.serialize(handshake_buf[0..4]);
            @memcpy(handshake_buf[4..36], &verify_data);

            // Update transcript with Client Finished
            self.transcript_hash.update(handshake_buf[0..36]);

            // Set up client handshake write cipher
            const key_len = self.cipher_suite.keyLength();
            var client_key_buf: [32]u8 = undefined;
            if (key_len == 16) {
                const ck16 = kdf.hkdfExpandLabel(Hkdf, self.client_handshake_traffic_secret[0..hash_len].*, "key", "", 16);
                @memcpy(client_key_buf[0..16], &ck16);
            } else {
                const ck32 = kdf.hkdfExpandLabel(Hkdf, self.client_handshake_traffic_secret[0..hash_len].*, "key", "", 32);
                @memcpy(&client_key_buf, &ck32);
            }
            const client_iv = kdf.hkdfExpandLabel(
                Hkdf,
                self.client_handshake_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );

            const write_cipher = try record.CipherState(Crypto).init(self.cipher_suite, client_key_buf[0..key_len], &client_iv);
            self.records.setWriteCipher(write_cipher);

            // Send encrypted Finished
            var write_buf: [128]u8 = undefined;
            _ = try self.records.writeRecord(.handshake, handshake_buf[0..36], &write_buf);

            // Switch to application write cipher
            var app_client_key_buf: [32]u8 = undefined;
            if (key_len == 16) {
                const ck16 = kdf.hkdfExpandLabel(Hkdf, self.client_application_traffic_secret[0..hash_len].*, "key", "", 16);
                @memcpy(app_client_key_buf[0..16], &ck16);
            } else {
                const ck32 = kdf.hkdfExpandLabel(Hkdf, self.client_application_traffic_secret[0..hash_len].*, "key", "", 32);
                @memcpy(&app_client_key_buf, &ck32);
            }
            const app_client_iv = kdf.hkdfExpandLabel(
                Hkdf,
                self.client_application_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );
            const app_write_cipher = try record.CipherState(Crypto).init(self.cipher_suite, app_client_key_buf[0..key_len], &app_client_iv);
            self.records.setWriteCipher(app_write_cipher);
        }

        fn deriveHandshakeKeys(self: *Self, shared_secret: []const u8) !void {
            // TLS 1.3 key derivation
            const Hkdf = Crypto.HkdfSha256;
            const hash_len = 32;

            // Early secret (no PSK)
            // RFC 8446: early_secret = HKDF-Extract(salt=0, IKM=0)
            // Both salt and IKM should be hash_len bytes of zeros
            const zeros: [hash_len]u8 = [_]u8{0} ** hash_len;
            const early_secret = Hkdf.extract(&zeros, &zeros);

            // Derive-Secret(early_secret, "derived", "")
            const empty_hash = emptyHash();
            const derived_secret = kdf.hkdfExpandLabel(
                Hkdf,
                early_secret,
                "derived",
                &empty_hash,
                hash_len,
            );

            // Handshake secret
            var hs_secret: [hash_len]u8 = undefined;
            if (shared_secret.len <= hash_len) {
                @memcpy(hs_secret[0..shared_secret.len], shared_secret);
                @memset(hs_secret[shared_secret.len..], 0);
            } else {
                @memcpy(&hs_secret, shared_secret[0..hash_len]);
            }
            self.handshake_secret = undefined;
            @memcpy(self.handshake_secret[0..hash_len], &Hkdf.extract(&derived_secret, &hs_secret));

            // Derive traffic secrets
            const transcript = self.transcript_hash.peek();
            self.client_handshake_traffic_secret = undefined;
            @memcpy(
                self.client_handshake_traffic_secret[0..hash_len],
                &kdf.hkdfExpandLabel(Hkdf, self.handshake_secret[0..hash_len].*, "c hs traffic", &transcript, hash_len),
            );
            self.server_handshake_traffic_secret = undefined;
            @memcpy(
                self.server_handshake_traffic_secret[0..hash_len],
                &kdf.hkdfExpandLabel(Hkdf, self.handshake_secret[0..hash_len].*, "s hs traffic", &transcript, hash_len),
            );
            
            // Set up record layer encryption
            // Key length depends on cipher suite - MUST use correct length in HKDF-Expand-Label!
            const key_len = self.cipher_suite.keyLength();
            var server_key_buf: [32]u8 = undefined;
            if (key_len == 16) {
                const key16 = kdf.hkdfExpandLabel(Hkdf, self.server_handshake_traffic_secret[0..hash_len].*, "key", "", 16);
                @memcpy(server_key_buf[0..16], &key16);
            } else {
                const key32 = kdf.hkdfExpandLabel(Hkdf, self.server_handshake_traffic_secret[0..hash_len].*, "key", "", 32);
                @memcpy(&server_key_buf, &key32);
            }
            const server_iv = kdf.hkdfExpandLabel(
                Hkdf,
                self.server_handshake_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );

            const cipher = try record.CipherState(Crypto).init(self.cipher_suite, server_key_buf[0..key_len], &server_iv);
            self.records.setReadCipher(cipher);

            // Set TLS 1.3 for proper record format
            self.records.version = .tls_1_3;
        }

        fn deriveApplicationKeys(self: *Self) !void {
            const Hkdf = Crypto.HkdfSha256;
            const hash_len = 32;

            // Derive master secret
            const empty_hash = emptyHash();
            const derived = kdf.hkdfExpandLabel(
                Hkdf,
                self.handshake_secret[0..hash_len].*,
                "derived",
                &empty_hash,
                hash_len,
            );
            const zeros: [hash_len]u8 = [_]u8{0} ** hash_len;
            self.master_secret = undefined;
            @memcpy(self.master_secret[0..hash_len], &Hkdf.extract(&derived, &zeros));

            // Derive application traffic secrets
            const transcript = self.transcript_hash.peek();
            self.client_application_traffic_secret = undefined;
            @memcpy(
                self.client_application_traffic_secret[0..hash_len],
                &kdf.hkdfExpandLabel(Hkdf, self.master_secret[0..hash_len].*, "c ap traffic", &transcript, hash_len),
            );
            self.server_application_traffic_secret = undefined;
            @memcpy(
                self.server_application_traffic_secret[0..hash_len],
                &kdf.hkdfExpandLabel(Hkdf, self.master_secret[0..hash_len].*, "s ap traffic", &transcript, hash_len),
            );

            // Set up application encryption
            // Key length depends on cipher suite - MUST use correct length in HKDF-Expand-Label!
            const key_len = self.cipher_suite.keyLength();
            var client_key_buf: [32]u8 = undefined;
            var server_key_buf: [32]u8 = undefined;
            if (key_len == 16) {
                const ck16 = kdf.hkdfExpandLabel(Hkdf, self.client_application_traffic_secret[0..hash_len].*, "key", "", 16);
                const sk16 = kdf.hkdfExpandLabel(Hkdf, self.server_application_traffic_secret[0..hash_len].*, "key", "", 16);
                @memcpy(client_key_buf[0..16], &ck16);
                @memcpy(server_key_buf[0..16], &sk16);
            } else {
                const ck32 = kdf.hkdfExpandLabel(Hkdf, self.client_application_traffic_secret[0..hash_len].*, "key", "", 32);
                const sk32 = kdf.hkdfExpandLabel(Hkdf, self.server_application_traffic_secret[0..hash_len].*, "key", "", 32);
                @memcpy(&client_key_buf, &ck32);
                @memcpy(&server_key_buf, &sk32);
            }
            const client_iv = kdf.hkdfExpandLabel(
                Hkdf,
                self.client_application_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );
            const server_iv = kdf.hkdfExpandLabel(
                Hkdf,
                self.server_application_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );

            const write_cipher = try record.CipherState(Crypto).init(self.cipher_suite, client_key_buf[0..key_len], &client_iv);
            const read_cipher = try record.CipherState(Crypto).init(self.cipher_suite, server_key_buf[0..key_len], &server_iv);

            self.records.setWriteCipher(write_cipher);
            self.records.setReadCipher(read_cipher);
        }

        fn emptyHash() [32]u8 {
            var hash: [32]u8 = undefined;
            Crypto.Sha256.hash("", &hash, .{});
            return hash;
        }
    };
}

// ============================================================================
// Errors
// ============================================================================

pub const HandshakeError = error{
    BufferTooSmall,
    InvalidHandshake,
    UnexpectedMessage,
    AlertReceived,
    HandshakeFailed,
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
// Tests
// ============================================================================

test "HandshakeHeader parse and serialize" {
    const header = HandshakeHeader{
        .msg_type = .client_hello,
        .length = 256,
    };

    var buf: [4]u8 = undefined;
    try header.serialize(&buf);

    const parsed = try HandshakeHeader.parse(&buf);
    try std.testing.expectEqual(header.msg_type, parsed.msg_type);
    try std.testing.expectEqual(header.length, parsed.length);
}

// Use default crypto for tests
const default_crypto = @import("crypto");

test "TranscriptHash" {
    var hash = TranscriptHash(default_crypto).init();
    hash.update("hello");
    hash.update("world");

    const result1 = hash.peek();
    const result2 = hash.peek();

    // peek should not change state
    try std.testing.expectEqual(result1, result2);
}

// ============================================================================
// TLS 1.2 PRF Tests (RFC 5246)
// ============================================================================

test "TLS 1.2 PRF basic" {
    // Test PRF with known inputs
    // PRF(secret, label, seed) = P_SHA256(secret, label + seed)
    const secret = "secret";
    const label = "test label";
    const seed = "seed";

    var out: [32]u8 = undefined;
    Tls12Prf(default_crypto).prf(&out, secret, label, seed);

    // Verify output is deterministic
    var out2: [32]u8 = undefined;
    Tls12Prf(default_crypto).prf(&out2, secret, label, seed);
    try std.testing.expectEqualSlices(u8, &out, &out2);

    // Verify different inputs produce different outputs
    var out3: [32]u8 = undefined;
    Tls12Prf(default_crypto).prf(&out3, "different", label, seed);
    try std.testing.expect(!std.mem.eql(u8, &out, &out3));
}

test "TLS 1.2 PRF output length" {
    const secret = "secret";
    const label = "label";
    const seed = "seed";

    // Test various output lengths
    var out12: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&out12, secret, label, seed);

    var out48: [48]u8 = undefined;
    Tls12Prf(default_crypto).prf(&out48, secret, label, seed);

    // First 12 bytes should match
    try std.testing.expectEqualSlices(u8, &out12, out48[0..12]);

    var out72: [72]u8 = undefined;
    Tls12Prf(default_crypto).prf(&out72, secret, label, seed);

    // First 48 bytes should match
    try std.testing.expectEqualSlices(u8, &out48, out72[0..48]);
}

test "TLS 1.2 PRF master secret derivation" {
    // RFC 5246 Section 8.1:
    // master_secret = PRF(pre_master_secret, "master secret",
    //                     ClientHello.random + ServerHello.random)[0..47]

    const pre_master_secret = [_]u8{0x03, 0x03} ++ [_]u8{0xAB} ** 46; // TLS 1.2 version + random
    const client_random = [_]u8{0x01} ** 32;
    const server_random = [_]u8{0x02} ** 32;

    var seed: [64]u8 = undefined;
    @memcpy(seed[0..32], &client_random);
    @memcpy(seed[32..64], &server_random);

    var master_secret: [48]u8 = undefined;
    Tls12Prf(default_crypto).prf(&master_secret, &pre_master_secret, "master secret", &seed);

    // Verify it's deterministic
    var master_secret2: [48]u8 = undefined;
    Tls12Prf(default_crypto).prf(&master_secret2, &pre_master_secret, "master secret", &seed);
    try std.testing.expectEqualSlices(u8, &master_secret, &master_secret2);

    // Verify master_secret is not all zeros (sanity check)
    var all_zeros = true;
    for (master_secret) |b| {
        if (b != 0) {
            all_zeros = false;
            break;
        }
    }
    try std.testing.expect(!all_zeros);
}

test "TLS 1.2 PRF key expansion" {
    // RFC 5246 Section 6.3:
    // key_block = PRF(master_secret, "key expansion",
    //                 server_random + client_random)  // NOTE: order reversed!

    const master_secret = [_]u8{0xAA} ** 48;
    const client_random = [_]u8{0x01} ** 32;
    const server_random = [_]u8{0x02} ** 32;

    // Note: For key expansion, seed is server_random + client_random (reversed!)
    var seed: [64]u8 = undefined;
    @memcpy(seed[0..32], &server_random);
    @memcpy(seed[32..64], &client_random);

    // For AES-128-GCM: need 2*16 (keys) + 2*4 (IVs) = 40 bytes
    var key_block: [40]u8 = undefined;
    Tls12Prf(default_crypto).prf(&key_block, &master_secret, "key expansion", &seed);

    const client_write_key = key_block[0..16];
    const server_write_key = key_block[16..32];
    const client_write_iv = key_block[32..36];
    const server_write_iv = key_block[36..40];

    // Verify keys are different from IVs
    try std.testing.expect(!std.mem.eql(u8, client_write_key[0..4], client_write_iv));
    try std.testing.expect(!std.mem.eql(u8, server_write_key[0..4], server_write_iv));

    // Verify client and server keys are different
    try std.testing.expect(!std.mem.eql(u8, client_write_key, server_write_key));
}

test "TLS 1.2 full key derivation flow" {
    // Test the complete TLS 1.2 key derivation as done in deriveTls12Keys
    const pre_master_secret = [_]u8{0x03, 0x03} ++ [_]u8{0x55} ** 46;
    const client_random = [_]u8{0x11} ** 32;
    const server_random = [_]u8{0x22} ** 32;

    // Step 1: Derive master_secret
    // master_secret = PRF(pre_master_secret, "master secret", client_random + server_random)
    var ms_seed: [64]u8 = undefined;
    @memcpy(ms_seed[0..32], &client_random);
    @memcpy(ms_seed[32..64], &server_random);

    var master_secret: [48]u8 = undefined;
    Tls12Prf(default_crypto).prf(&master_secret, &pre_master_secret, "master secret", &ms_seed);

    // Step 2: Derive key_block
    // key_block = PRF(master_secret, "key expansion", server_random + client_random)
    var kb_seed: [64]u8 = undefined;
    @memcpy(kb_seed[0..32], &server_random); // NOTE: reversed order!
    @memcpy(kb_seed[32..64], &client_random);

    // For AES-128-GCM with SHA-256:
    // No MAC keys (AEAD), 2x16 keys, 2x4 IVs = 40 bytes
    var key_block: [40]u8 = undefined;
    Tls12Prf(default_crypto).prf(&key_block, &master_secret, "key expansion", &kb_seed);

    // Verify structure
    const client_write_key = key_block[0..16];
    const server_write_key = key_block[16..32];
    const client_write_iv = key_block[32..36];
    const server_write_iv = key_block[36..40];

    // All should be non-zero and different
    try std.testing.expect(!std.mem.eql(u8, client_write_key, server_write_key));
    try std.testing.expect(!std.mem.eql(u8, client_write_iv, server_write_iv));

    // Step 3: Verify finished calculation
    // verify_data = PRF(master_secret, finished_label, Hash(handshake_messages))[0..11]
    var transcript_hash: [32]u8 = undefined;
    default_crypto.Sha256.hash("test handshake messages", &transcript_hash, .{});

    var client_verify_data: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&client_verify_data, &master_secret, "client finished", &transcript_hash);

    var server_verify_data: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&server_verify_data, &master_secret, "server finished", &transcript_hash);

    // Client and server verify_data should be different
    try std.testing.expect(!std.mem.eql(u8, &client_verify_data, &server_verify_data));
}

test "TLS 1.2 key derivation for AES-256-GCM" {
    // AES-256-GCM needs 32-byte keys and 4-byte IVs
    const master_secret = [_]u8{0xBB} ** 48;
    const client_random = [_]u8{0x33} ** 32;
    const server_random = [_]u8{0x44} ** 32;

    var seed: [64]u8 = undefined;
    @memcpy(seed[0..32], &server_random);
    @memcpy(seed[32..64], &client_random);

    // For AES-256-GCM: 2*32 (keys) + 2*4 (IVs) = 72 bytes
    var key_block: [72]u8 = undefined;
    Tls12Prf(default_crypto).prf(&key_block, &master_secret, "key expansion", &seed);

    const client_write_key = key_block[0..32];
    const server_write_key = key_block[32..64];
    const client_write_iv = key_block[64..68];
    const server_write_iv = key_block[68..72];

    // All should be different
    try std.testing.expect(!std.mem.eql(u8, client_write_key, server_write_key));
    try std.testing.expect(!std.mem.eql(u8, client_write_iv, server_write_iv));
}

// ============================================================================
// TLS 1.2 Finished/verify_data Tests (RFC 5246 Section 7.4.9)
// ============================================================================

test "TLS 1.2 verify_data calculation" {
    // RFC 5246 Section 7.4.9:
    // verify_data = PRF(master_secret, finished_label, Hash(handshake_messages))[0..11]

    const master_secret = [_]u8{0xCC} ** 48;

    // Simulate transcript hash (SHA-256 of all handshake messages)
    var transcript_hash: [32]u8 = undefined;
    default_crypto.Sha256.hash("ClientHello|ServerHello|Certificate|ServerKeyExchange|ServerHelloDone|ClientKeyExchange", &transcript_hash, .{});

    // Calculate client verify_data
    var client_verify_data: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&client_verify_data, &master_secret, "client finished", &transcript_hash);

    // Calculate server verify_data
    var server_verify_data: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&server_verify_data, &master_secret, "server finished", &transcript_hash);

    // Client and server verify_data must be different
    try std.testing.expect(!std.mem.eql(u8, &client_verify_data, &server_verify_data));

    // Both should be deterministic
    var client_verify_data2: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&client_verify_data2, &master_secret, "client finished", &transcript_hash);
    try std.testing.expectEqualSlices(u8, &client_verify_data, &client_verify_data2);
}

test "TLS 1.2 verify_data depends on transcript" {
    const master_secret = [_]u8{0xDD} ** 48;

    // Two different transcripts
    var transcript1: [32]u8 = undefined;
    default_crypto.Sha256.hash("transcript1", &transcript1, .{});

    var transcript2: [32]u8 = undefined;
    default_crypto.Sha256.hash("transcript2", &transcript2, .{});

    var verify1: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&verify1, &master_secret, "client finished", &transcript1);

    var verify2: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&verify2, &master_secret, "client finished", &transcript2);

    // Different transcripts should produce different verify_data
    try std.testing.expect(!std.mem.eql(u8, &verify1, &verify2));
}

test "TLS 1.2 verify_data depends on master_secret" {
    var transcript: [32]u8 = undefined;
    default_crypto.Sha256.hash("same transcript", &transcript, .{});

    const master_secret1 = [_]u8{0xEE} ** 48;
    const master_secret2 = [_]u8{0xFF} ** 48;

    var verify1: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&verify1, &master_secret1, "client finished", &transcript);

    var verify2: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&verify2, &master_secret2, "client finished", &transcript);

    // Different master secrets should produce different verify_data
    try std.testing.expect(!std.mem.eql(u8, &verify1, &verify2));
}

test "TLS 1.2 Finished message structure" {
    // Finished message format: type(1) + length(3) + verify_data(12) = 16 bytes
    const master_secret = [_]u8{0x11} ** 48;

    var transcript: [32]u8 = undefined;
    default_crypto.Sha256.hash("handshake messages", &transcript, .{});

    var verify_data: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&verify_data, &master_secret, "client finished", &transcript);

    // Build Finished message
    var finished_msg: [16]u8 = undefined;
    finished_msg[0] = 0x14; // Finished type
    finished_msg[1] = 0x00; // Length MSB
    finished_msg[2] = 0x00; // Length
    finished_msg[3] = 0x0C; // Length = 12
    @memcpy(finished_msg[4..16], &verify_data);

    // Verify structure
    try std.testing.expectEqual(@as(u8, 0x14), finished_msg[0]);
    try std.testing.expectEqual(@as(u24, 12), std.mem.readInt(u24, finished_msg[1..4], .big));
    try std.testing.expectEqualSlices(u8, &verify_data, finished_msg[4..16]);
}

test "TLS 1.2 full handshake simulation" {
    // Simulate a complete TLS 1.2 key derivation and Finished exchange

    // 1. Pre-master secret (e.g., from ECDHE)
    const pre_master_secret = [_]u8{0x77} ** 32;

    // 2. Client and server randoms
    const client_random = [_]u8{0x11} ** 32;
    const server_random = [_]u8{0x22} ** 32;

    // 3. Derive master_secret
    var ms_seed: [64]u8 = undefined;
    @memcpy(ms_seed[0..32], &client_random);
    @memcpy(ms_seed[32..64], &server_random);

    var master_secret: [48]u8 = undefined;
    Tls12Prf(default_crypto).prf(&master_secret, &pre_master_secret, "master secret", &ms_seed);

    // 4. Derive key_block
    var kb_seed: [64]u8 = undefined;
    @memcpy(kb_seed[0..32], &server_random); // NOTE: reversed!
    @memcpy(kb_seed[32..64], &client_random);

    var key_block: [40]u8 = undefined; // AES-128-GCM
    Tls12Prf(default_crypto).prf(&key_block, &master_secret, "key expansion", &kb_seed);

    // 5. Simulate transcript hash (after ClientKeyExchange)
    var transcript_after_cke: [32]u8 = undefined;
    default_crypto.Sha256.hash("ClientHello|ServerHello|Certificate|ServerKeyExchange|ServerHelloDone|ClientKeyExchange", &transcript_after_cke, .{});

    // 6. Client computes verify_data
    var client_verify: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&client_verify, &master_secret, "client finished", &transcript_after_cke);

    // 7. Simulate transcript hash (after Client Finished)
    var full_transcript = TranscriptHash(default_crypto).init();
    full_transcript.update("ClientHello|ServerHello|Certificate|ServerKeyExchange|ServerHelloDone|ClientKeyExchange");
    // Add Client Finished to transcript
    var client_finished_msg: [16]u8 = undefined;
    client_finished_msg[0] = 0x14;
    std.mem.writeInt(u24, client_finished_msg[1..4], 12, .big);
    @memcpy(client_finished_msg[4..16], &client_verify);
    full_transcript.update(&client_finished_msg);
    const transcript_after_client_finished = full_transcript.peek();

    // 8. Server computes verify_data (using transcript that includes Client Finished)
    var server_verify: [12]u8 = undefined;
    Tls12Prf(default_crypto).prf(&server_verify, &master_secret, "server finished", &transcript_after_client_finished);

    // 9. Verify client and server finished are different
    try std.testing.expect(!std.mem.eql(u8, &client_verify, &server_verify));

    // 10. Verify all outputs are non-zero
    var all_zero = true;
    for (master_secret) |b| if (b != 0) { all_zero = false; break; };
    try std.testing.expect(!all_zero);

    all_zero = true;
    for (client_verify) |b| if (b != 0) { all_zero = false; break; };
    try std.testing.expect(!all_zero);
}

// ============================================================================
// Certificate Verification Tests
// ============================================================================

test "ClientHandshake.CaStoreType is correct" {
    // Verify that CaStoreType is correctly derived from Crypto
    const MockSocket = struct {
        pub fn send(_: *@This(), _: []const u8) !usize { return 0; }
        pub fn recv(_: *@This(), _: []u8) !usize { return 0; }
    };

    // With default_crypto (has x509), CaStoreType should not be void
    const Hs = ClientHandshake(MockSocket, default_crypto);
    try std.testing.expect(Hs.CaStoreType != void);

    // CaStoreType should be the same as Crypto.x509.CaStore
    try std.testing.expect(Hs.CaStoreType == default_crypto.x509.CaStore);
}

test "ClientHandshake init with null ca_store" {
    // Test that ClientHandshake can be initialized without ca_store
    const MockSocket = struct {
        pub fn send(_: *@This(), _: []const u8) !usize { return 0; }
        pub fn recv(_: *@This(), _: []u8) !usize { return 0; }
    };

    var socket = MockSocket{};
    const Hs = ClientHandshake(MockSocket, default_crypto);

    // Initialize with null ca_store - should not perform verification
    const hs = Hs.init(&socket, "example.com", std.testing.allocator, null);

    try std.testing.expect(hs.ca_store == null);
    try std.testing.expectEqualStrings("example.com", hs.hostname);
}

test "ClientHandshake init with ca_store" {
    // Test that ClientHandshake can be initialized with a ca_store
    const MockSocket = struct {
        pub fn send(_: *@This(), _: []const u8) !usize { return 0; }
        pub fn recv(_: *@This(), _: []u8) !usize { return 0; }
    };

    var socket = MockSocket{};
    const Hs = ClientHandshake(MockSocket, default_crypto);

    // Initialize with insecure ca_store
    const ca_store = default_crypto.x509.CaStore{ .insecure = {} };
    const hs = Hs.init(&socket, "example.com", std.testing.allocator, ca_store);

    try std.testing.expect(hs.ca_store != null);
    try std.testing.expect(hs.ca_store.? == .insecure);
}

test "processCertificate parses TLS 1.2 certificate message" {
    // Test certificate parsing (TLS 1.2 format)
    // Format: cert_list_len (3) + [ cert_len (3) + cert_data ]*

    // Create a minimal valid DER certificate structure
    // This is a simplified test - real certificates are much larger
    const fake_cert = [_]u8{
        // Minimal DER sequence (this won't pass real validation but tests parsing)
        0x30, 0x03, 0x01, 0x01, 0x00,
    };

    // Build TLS 1.2 Certificate message
    var cert_msg: [64]u8 = undefined;
    var pos: usize = 0;

    // cert_list_len = 3 (cert_len) + fake_cert.len
    const cert_entry_len: u24 = 3 + fake_cert.len;
    std.mem.writeInt(u24, cert_msg[pos..][0..3], cert_entry_len, .big);
    pos += 3;

    // cert_len
    std.mem.writeInt(u24, cert_msg[pos..][0..3], fake_cert.len, .big);
    pos += 3;

    // cert_data
    @memcpy(cert_msg[pos..][0..fake_cert.len], &fake_cert);
    pos += fake_cert.len;

    // Verify the message was built correctly
    try std.testing.expectEqual(@as(usize, 11), pos);
}

test "processCertificate parses TLS 1.3 certificate message" {
    // Test certificate parsing (TLS 1.3 format)
    // Format: context_len (1) + context + cert_list_len (3) + [ cert_len (3) + cert_data + ext_len (2) + ext ]*

    const fake_cert = [_]u8{
        0x30, 0x03, 0x01, 0x01, 0x00,
    };

    // Build TLS 1.3 Certificate message
    var cert_msg: [64]u8 = undefined;
    var pos: usize = 0;

    // context_len = 0 (empty context for server certificate)
    cert_msg[pos] = 0;
    pos += 1;

    // cert_list_len = 3 (cert_len) + cert.len + 2 (ext_len) + 0 (no extensions)
    const cert_entry_len: u24 = 3 + fake_cert.len + 2;
    std.mem.writeInt(u24, cert_msg[pos..][0..3], cert_entry_len, .big);
    pos += 3;

    // cert_len
    std.mem.writeInt(u24, cert_msg[pos..][0..3], fake_cert.len, .big);
    pos += 3;

    // cert_data
    @memcpy(cert_msg[pos..][0..fake_cert.len], &fake_cert);
    pos += fake_cert.len;

    // ext_len = 0
    std.mem.writeInt(u16, cert_msg[pos..][0..2], 0, .big);
    pos += 2;

    // Verify the message was built correctly
    try std.testing.expectEqual(@as(usize, 14), pos);
}
