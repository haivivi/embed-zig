//! TLS Handshake Protocol
//!
//! Implements the TLS handshake state machine for both TLS 1.2 and TLS 1.3.
//! Reference: RFC 8446 (TLS 1.3), RFC 5246 (TLS 1.2)

const std = @import("std");
const crypto = @import("crypto");
const common = @import("common.zig");
const extensions = @import("extensions.zig");
const record = @import("record.zig");

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
// Key Exchange
// ============================================================================

pub const KeyExchange = union(enum) {
    x25519: X25519KeyExchange,
    secp256r1: P256KeyExchange,
    secp384r1: P384KeyExchange,

    pub fn generate(group: NamedGroup, rng_fill: *const fn ([]u8) void) !KeyExchange {
        return switch (group) {
            .x25519 => .{ .x25519 = try X25519KeyExchange.generate(rng_fill) },
            .secp256r1 => .{ .secp256r1 = try P256KeyExchange.generate(rng_fill) },
            .secp384r1 => .{ .secp384r1 = try P384KeyExchange.generate(rng_fill) },
            else => error.UnsupportedGroup,
        };
    }

    pub fn publicKey(self: *const KeyExchange) []const u8 {
        return switch (self.*) {
            .x25519 => |*kx| &kx.public_key,
            .secp256r1 => |*kx| &kx.public_key,
            .secp384r1 => |*kx| &kx.public_key,
        };
    }

    pub fn computeSharedSecret(self: *KeyExchange, peer_public: []const u8) ![]const u8 {
        return switch (self.*) {
            .x25519 => |*kx| try kx.computeSharedSecret(peer_public),
            .secp256r1 => |*kx| try kx.computeSharedSecret(peer_public),
            .secp384r1 => |*kx| try kx.computeSharedSecret(peer_public),
        };
    }
};

const X25519KeyExchange = struct {
    secret_key: [32]u8,
    public_key: [32]u8,
    shared_secret: [32]u8,

    pub fn generate(rng_fill: *const fn ([]u8) void) !X25519KeyExchange {
        var self: X25519KeyExchange = undefined;
        rng_fill(&self.secret_key);
        const kp = try crypto.ecc.X25519.KeyPair.generateDeterministic(self.secret_key);
        self.public_key = kp.public_key;
        return self;
    }

    pub fn computeSharedSecret(self: *X25519KeyExchange, peer_public: []const u8) ![]const u8 {
        if (peer_public.len != 32) return error.InvalidPublicKey;
        self.shared_secret = try crypto.ecc.X25519.scalarmult(
            self.secret_key,
            peer_public[0..32].*,
        );
        return &self.shared_secret;
    }
};

const P256KeyExchange = struct {
    secret_key: [32]u8,
    public_key: [65]u8, // Uncompressed SEC1 format
    shared_secret: [32]u8,

    pub fn generate(rng_fill: *const fn ([]u8) void) !P256KeyExchange {
        var self: P256KeyExchange = undefined;
        rng_fill(&self.secret_key);
        const kp = try crypto.sign.EcdsaP256Sha256.KeyPair.generateDeterministic(self.secret_key);
        self.public_key = kp.public_key.toUncompressedSec1();
        return self;
    }

    pub fn computeSharedSecret(self: *P256KeyExchange, peer_public: []const u8) ![]const u8 {
        const pk = try crypto.sign.EcdsaP256Sha256.PublicKey.fromSec1(peer_public);
        const result = try pk.p.mulPublic(self.secret_key, .big);
        const coords = result.affineCoordinates();
        self.shared_secret = coords.x.toBytes(.big);
        return &self.shared_secret;
    }
};

const P384KeyExchange = struct {
    secret_key: [48]u8,
    public_key: [97]u8, // Uncompressed SEC1 format
    shared_secret: [48]u8,

    pub fn generate(rng_fill: *const fn ([]u8) void) !P384KeyExchange {
        var self: P384KeyExchange = undefined;
        rng_fill(&self.secret_key);
        const kp = try crypto.sign.EcdsaP384Sha384.KeyPair.generateDeterministic(self.secret_key);
        self.public_key = kp.public_key.toUncompressedSec1();
        return self;
    }

    pub fn computeSharedSecret(self: *P384KeyExchange, peer_public: []const u8) ![]const u8 {
        const pk = try crypto.sign.EcdsaP384Sha384.PublicKey.fromSec1(peer_public);
        const result = try pk.p.mulPublic(self.secret_key, .big);
        const coords = result.affineCoordinates();
        self.shared_secret = coords.x.toBytes(.big);
        return &self.shared_secret;
    }
};

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
};

// ============================================================================
// Client Handshake
// ============================================================================

pub fn ClientHandshake(comptime Socket: type, comptime Rng: type) type {
    return struct {
        // Connection state
        state: HandshakeState,
        version: ProtocolVersion,
        cipher_suite: CipherSuite,

        // Random values
        client_random: [32]u8,
        server_random: [32]u8,

        // Key exchange
        key_exchange: ?KeyExchange,

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

        // Transcript hash
        transcript_hash: TranscriptHash,

        // Record layer
        records: record.RecordLayer(Socket),

        // Configuration
        hostname: []const u8,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(
            socket: *Socket,
            hostname: []const u8,
            allocator: std.mem.Allocator,
        ) Self {
            var self = Self{
                .state = .initial,
                .version = .tls_1_3,
                .cipher_suite = .TLS_AES_128_GCM_SHA256,
                .client_random = undefined,
                .server_random = undefined,
                .key_exchange = null,
                .handshake_secret = undefined,
                .master_secret = undefined,
                .client_handshake_traffic_secret = undefined,
                .server_handshake_traffic_secret = undefined,
                .client_application_traffic_secret = undefined,
                .server_application_traffic_secret = undefined,
                .tls12_server_pubkey = undefined,
                .tls12_server_pubkey_len = 0,
                .tls12_named_group = .x25519,
                .transcript_hash = TranscriptHash.init(),
                .records = record.RecordLayer(Socket).init(socket),
                .hostname = hostname,
                .allocator = allocator,
            };

            // Generate client random
            Rng.fill(&self.client_random);

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

            // Cipher suites
            const cipher_suites = [_]CipherSuite{
                .TLS_AES_128_GCM_SHA256,
                .TLS_AES_256_GCM_SHA384,
                .TLS_CHACHA20_POLY1305_SHA256,
                .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
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

            // Supported versions
            const versions = [_]ProtocolVersion{ .tls_1_3, .tls_1_2 };
            try ext_builder.addSupportedVersions(&versions);

            // Supported groups
            const groups = [_]NamedGroup{ .x25519, .secp256r1, .secp384r1 };
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
            self.key_exchange = try KeyExchange.generate(.x25519, &Rng.fill);
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
                    if (result.length >= 2) {
                        const level = plaintext[0];
                        const desc = plaintext[1];
                        _ = level;
                        _ = desc;
                    }
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
            if (data.len < 4) return error.InvalidHandshake;

            const header = try HandshakeHeader.parse(data);
            const msg_data = data[4..][0..header.length];

            // Update transcript
            self.transcript_hash.update(data[0 .. 4 + header.length]);

            switch (header.msg_type) {
                .server_hello => try self.processServerHello(msg_data),
                .encrypted_extensions => try self.processEncryptedExtensions(msg_data),
                .certificate => try self.processCertificate(msg_data),
                .server_key_exchange => try self.processServerKeyExchange(msg_data),
                .server_hello_done => try self.processServerHelloDone(msg_data),
                .certificate_verify => try self.processCertificateVerify(msg_data),
                .finished => try self.processFinished(msg_data),
                else => {
                    // Skip unknown messages in some states
                },
            }
        }

        fn processServerHello(self: *Self, data: []const u8) !void {
            if (self.state != .wait_server_hello) return error.UnexpectedMessage;
            if (data.len < 34) return error.InvalidHandshake;

            // Parse legacy version
            const legacy_version: ProtocolVersion = @enumFromInt(
                std.mem.readInt(u16, data[0..2], .big),
            );

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

            // Session ID
            const session_id_len = data[pos];
            pos += 1 + session_id_len;

            // Cipher suite
            if (pos + 2 > data.len) return error.InvalidHandshake;
            self.cipher_suite = @enumFromInt(std.mem.readInt(u16, data[pos..][0..2], .big));
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
                        const ext_type: common.ExtensionType = @enumFromInt(
                            std.mem.readInt(u16, ext_data[ext_pos..][0..2], .big),
                        );
                        ext_pos += 2;
                        const ext_size = std.mem.readInt(u16, ext_data[ext_pos..][0..2], .big);
                        ext_pos += 2;

                        const ext_content = ext_data[ext_pos..][0..ext_size];
                        ext_pos += ext_size;

                        switch (ext_type) {
                            .supported_versions => {
                                self.version = try extensions.parseSupportedVersion(ext_content);
                            },
                            .key_share => {
                                const key_share = try extensions.parseKeyShareServer(ext_content);
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
                const context_len = data[0];
                pos = 1 + context_len;
            }

            // Certificate list length
            if (pos + 3 > data.len) return error.InvalidHandshake;
            const certs_len = std.mem.readInt(u24, data[pos..][0..3], .big);
            pos += 3;
            _ = certs_len;

            // TODO: Parse and verify certificates
            // For now, just move to next state

            if (self.version == .tls_1_3) {
                self.state = .wait_certificate_verify;
            } else {
                self.state = .wait_finished;
            }
        }

        /// Process TLS 1.2 ServerKeyExchange message
        fn processServerKeyExchange(self: *Self, data: []const u8) !void {
            if (self.version == .tls_1_3) return error.UnexpectedMessage;
            if (self.state != .wait_certificate) return error.UnexpectedMessage;

            // Parse ECDHE parameters
            // Format: curve_type (1) + named_curve (2) + pubkey_len (1) + pubkey + signature
            if (data.len < 4) return error.InvalidHandshake;

            const curve_type = data[0];
            if (curve_type != 0x03) return error.UnsupportedGroup; // named_curve

            const named_group: NamedGroup = @enumFromInt(
                std.mem.readInt(u16, data[1..3], .big),
            );
            const pubkey_len = data[3];

            if (data.len < 4 + pubkey_len) return error.InvalidHandshake;
            const server_pubkey = data[4..][0..pubkey_len];

            // Generate our key exchange if not already done
            if (self.key_exchange == null) {
                self.key_exchange = try KeyExchange.generate(named_group, &Rng.fill);
            }

            // Store server's public key for later (we'll compute shared secret in ClientKeyExchange)
            // For now, just store in a temporary location
            @memcpy(self.tls12_server_pubkey[0..pubkey_len], server_pubkey);
            self.tls12_server_pubkey_len = pubkey_len;
            self.tls12_named_group = named_group;

            // TODO: Verify signature over ServerKeyExchange params
            // The signature is at data[4 + pubkey_len..]

            // Stay in certificate state, wait for ServerHelloDone
        }

        /// Process TLS 1.2 ServerHelloDone message
        fn processServerHelloDone(self: *Self, data: []const u8) !void {
            if (self.version == .tls_1_3) return error.UnexpectedMessage;
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
            // Compute verify_data
            const hash_len = 32;
            const verify_data = self.computeVerifyData(true); // client

            var handshake_buf: [64]u8 = undefined;
            const header = HandshakeHeader{
                .msg_type = .finished,
                .length = 12, // verify_data is always 12 bytes in TLS 1.2
            };
            try header.serialize(handshake_buf[0..4]);
            @memcpy(handshake_buf[4..16], verify_data[0..12]);

            // Send encrypted record
            var write_buf: [128]u8 = undefined;
            _ = try self.records.writeRecord(.handshake, handshake_buf[0..16], &write_buf);
            _ = hash_len;
        }

        /// Derive TLS 1.2 keys from pre-master secret
        fn deriveTls12Keys(self: *Self, pre_master_secret: []const u8) !void {
            const Prf = Tls12Prf;

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
            const write_cipher = try record.CipherState.init(self.cipher_suite, client_write_key, &client_iv);
            const read_cipher = try record.CipherState.init(self.cipher_suite, server_write_key, &server_iv);

            self.records.setWriteCipher(write_cipher);
            self.records.setReadCipher(read_cipher);
        }

        /// Compute verify_data for Finished message
        fn computeVerifyData(self: *Self, is_client: bool) [12]u8 {
            const Prf = Tls12Prf;
            const label = if (is_client) "client finished" else "server finished";

            const transcript = self.transcript_hash.peek();
            var verify_data: [12]u8 = undefined;
            Prf.prf(&verify_data, self.master_secret[0..48], label, &transcript);
            return verify_data;
        }

        fn processCertificateVerify(self: *Self, data: []const u8) !void {
            if (self.state != .wait_certificate_verify) return error.UnexpectedMessage;
            _ = data; // TODO: Verify signature
            self.state = .wait_finished;
        }

        fn processFinished(self: *Self, data: []const u8) !void {
            if (self.state != .wait_finished) return error.UnexpectedMessage;
            _ = data; // TODO: Verify finished message

            // Derive application keys
            try self.deriveApplicationKeys();

            self.state = .connected;
        }

        fn deriveHandshakeKeys(self: *Self, shared_secret: []const u8) !void {
            // TLS 1.3 key derivation
            const Hkdf = crypto.kdf.HkdfSha256;
            const hash_len = 32;

            // Early secret (no PSK)
            const zeros: [hash_len]u8 = [_]u8{0} ** hash_len;
            const early_secret = Hkdf.extract(&[_]u8{0}, &zeros);

            // Derive-Secret(early_secret, "derived", "")
            const empty_hash = emptyHash();
            const derived_secret = crypto.kdf.hkdfExpandLabel(
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
                &crypto.kdf.hkdfExpandLabel(Hkdf, self.handshake_secret[0..hash_len].*, "c hs traffic", &transcript, hash_len),
            );
            self.server_handshake_traffic_secret = undefined;
            @memcpy(
                self.server_handshake_traffic_secret[0..hash_len],
                &crypto.kdf.hkdfExpandLabel(Hkdf, self.handshake_secret[0..hash_len].*, "s hs traffic", &transcript, hash_len),
            );

            // Set up record layer encryption
            const server_key = crypto.kdf.hkdfExpandLabel(
                Hkdf,
                self.server_handshake_traffic_secret[0..hash_len].*,
                "key",
                "",
                16,
            );
            const server_iv = crypto.kdf.hkdfExpandLabel(
                Hkdf,
                self.server_handshake_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );

            const cipher = try record.CipherState.init(self.cipher_suite, &server_key, &server_iv);
            self.records.setReadCipher(cipher);
        }

        fn deriveApplicationKeys(self: *Self) !void {
            const Hkdf = crypto.kdf.HkdfSha256;
            const hash_len = 32;

            // Derive master secret
            const empty_hash = emptyHash();
            const derived = crypto.kdf.hkdfExpandLabel(
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
                &crypto.kdf.hkdfExpandLabel(Hkdf, self.master_secret[0..hash_len].*, "c ap traffic", &transcript, hash_len),
            );
            self.server_application_traffic_secret = undefined;
            @memcpy(
                self.server_application_traffic_secret[0..hash_len],
                &crypto.kdf.hkdfExpandLabel(Hkdf, self.master_secret[0..hash_len].*, "s ap traffic", &transcript, hash_len),
            );

            // Set up application encryption
            const client_key = crypto.kdf.hkdfExpandLabel(
                Hkdf,
                self.client_application_traffic_secret[0..hash_len].*,
                "key",
                "",
                16,
            );
            const client_iv = crypto.kdf.hkdfExpandLabel(
                Hkdf,
                self.client_application_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );
            const server_key = crypto.kdf.hkdfExpandLabel(
                Hkdf,
                self.server_application_traffic_secret[0..hash_len].*,
                "key",
                "",
                16,
            );
            const server_iv = crypto.kdf.hkdfExpandLabel(
                Hkdf,
                self.server_application_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );

            const write_cipher = try record.CipherState.init(self.cipher_suite, &client_key, &client_iv);
            const read_cipher = try record.CipherState.init(self.cipher_suite, &server_key, &server_iv);

            self.records.setWriteCipher(write_cipher);
            self.records.setReadCipher(read_cipher);
        }

        fn emptyHash() [32]u8 {
            var hash: [32]u8 = undefined;
            crypto.hash.Sha256.hash("", &hash, .{});
            return hash;
        }
    };
}

// ============================================================================
// Transcript Hash
// ============================================================================

const TranscriptHash = struct {
    sha256: crypto.hash.Sha256,

    pub fn init() TranscriptHash {
        return TranscriptHash{
            .sha256 = crypto.hash.Sha256.init(.{}),
        };
    }

    pub fn update(self: *TranscriptHash, data: []const u8) void {
        self.sha256.update(data);
    }

    pub fn peek(self: *TranscriptHash) [32]u8 {
        var copy = self.sha256;
        var result: [32]u8 = undefined;
        copy.final(&result);
        return result;
    }

    pub fn final(self: *TranscriptHash, out: *[32]u8) void {
        self.sha256.final(out);
    }
};

// ============================================================================
// TLS 1.2 PRF (Pseudo-Random Function)
// ============================================================================

const Tls12Prf = struct {
    /// TLS 1.2 PRF based on HMAC-SHA256
    /// P_hash(secret, seed) = HMAC_hash(secret, A(1) + seed) +
    ///                        HMAC_hash(secret, A(2) + seed) + ...
    /// where A(0) = seed, A(i) = HMAC_hash(secret, A(i-1))
    pub fn prf(out: []u8, secret: []const u8, label: []const u8, seed: []const u8) void {
        const Hmac = crypto.auth.HmacSha256;

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
            var p: [32]u8 = undefined;
            ctx.final(&p);

            // Copy to output
            const copy_len = @min(32, out.len - pos);
            @memcpy(out[pos..][0..copy_len], p[0..copy_len]);
            pos += copy_len;

            // A(i+1) = HMAC(secret, A(i))
            Hmac.create(&a, &a, secret);
        }
    }
};

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

test "TranscriptHash" {
    var hash = TranscriptHash.init();
    hash.update("hello");
    hash.update("world");

    const result1 = hash.peek();
    const result2 = hash.peek();

    // peek should not change state
    try std.testing.expectEqual(result1, result2);
}
