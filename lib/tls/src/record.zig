//! TLS Record Layer
//!
//! Implements the TLS record protocol (RFC 8446 Section 5).
//! Handles encryption/decryption of TLS records.
//!
//! Generic over Crypto type to support different cryptographic implementations.

const std = @import("std");
const common = @import("common.zig");

const ContentType = common.ContentType;
const ProtocolVersion = common.ProtocolVersion;
const CipherSuite = common.CipherSuite;
const Alert = common.Alert;
const AlertDescription = common.AlertDescription;
const AlertLevel = common.AlertLevel;

// ============================================================================
// Record Header
// ============================================================================

pub const RecordHeader = struct {
    content_type: ContentType,
    legacy_version: ProtocolVersion,
    length: u16,

    pub const SIZE = 5;

    pub fn parse(buf: []const u8) !RecordHeader {
        if (buf.len < SIZE) return error.BufferTooSmall;

        return RecordHeader{
            .content_type = @enumFromInt(buf[0]),
            .legacy_version = @enumFromInt(std.mem.readInt(u16, buf[1..3], .big)),
            .length = std.mem.readInt(u16, buf[3..5], .big),
        };
    }

    pub fn serialize(self: RecordHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;

        buf[0] = @intFromEnum(self.content_type);
        std.mem.writeInt(u16, buf[1..3], @intFromEnum(self.legacy_version), .big);
        std.mem.writeInt(u16, buf[3..5], self.length, .big);
    }
};

// ============================================================================
// Record Encryption/Decryption (Generic over Crypto)
// ============================================================================

/// Cipher state for encrypting/decrypting records
/// Generic over Crypto type to support different implementations
pub fn CipherState(comptime Crypto: type) type {
    return union(enum) {
        /// No encryption (initial state)
        none,
        /// AES-128-GCM
        aes_128_gcm: AesGcmState(Crypto, 16),
        /// AES-256-GCM
        aes_256_gcm: AesGcmState(Crypto, 32),
        /// ChaCha20-Poly1305
        chacha20_poly1305: ChaChaState(Crypto),

        const Self = @This();

        pub fn init(suite: CipherSuite, key: []const u8, iv: []const u8) !Self {
            return switch (suite) {
                .TLS_AES_128_GCM_SHA256,
                .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                => .{ .aes_128_gcm = try AesGcmState(Crypto, 16).init(key, iv) },

                .TLS_AES_256_GCM_SHA384,
                .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                => .{ .aes_256_gcm = try AesGcmState(Crypto, 32).init(key, iv) },

                .TLS_CHACHA20_POLY1305_SHA256,
                .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                => .{ .chacha20_poly1305 = try ChaChaState(Crypto).init(key, iv) },

                else => return error.UnsupportedCipherSuite,
            };
        }
    };
}

fn AesGcmState(comptime Crypto: type, comptime key_len: usize) type {
    return struct {
        key: [key_len]u8,
        iv: [12]u8,

        const Self = @This();
        const AEAD = if (key_len == 16)
            Crypto.Aes128Gcm
        else
            Crypto.Aes256Gcm;

        pub fn init(key: []const u8, iv: []const u8) !Self {
            if (key.len != key_len) return error.InvalidKeyLength;
            if (iv.len != 12) return error.InvalidIvLength;

            var self: Self = undefined;
            @memcpy(&self.key, key);
            @memcpy(&self.iv, iv);
            return self;
        }

        pub fn encrypt(
            self: *Self,
            ciphertext: []u8,
            tag: *[16]u8,
            plaintext: []const u8,
            additional_data: []const u8,
            seq_num: u64,
        ) void {
            const nonce = self.computeNonce(seq_num);
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        /// TLS 1.2 encryption with explicit nonce
        /// nonce = implicit_iv(first 4 bytes) || explicit_nonce(8 bytes)
        pub fn encryptTls12(
            self: *Self,
            ciphertext: []u8,
            tag: *[16]u8,
            plaintext: []const u8,
            additional_data: []const u8,
            explicit_nonce: *const [8]u8,
        ) void {
            var nonce: [12]u8 = undefined;
            @memcpy(nonce[0..4], self.iv[0..4]); // implicit IV (first 4 bytes)
            @memcpy(nonce[4..12], explicit_nonce); // explicit nonce (8 bytes)
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        pub fn decrypt(
            self: *Self,
            plaintext: []u8,
            ciphertext: []const u8,
            tag: [16]u8,
            additional_data: []const u8,
            seq_num: u64,
        ) !void {
            const nonce = self.computeNonce(seq_num);
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        /// TLS 1.2 decryption with explicit nonce
        pub fn decryptTls12(
            self: *Self,
            plaintext: []u8,
            ciphertext: []const u8,
            tag: [16]u8,
            additional_data: []const u8,
            explicit_nonce: *const [8]u8,
        ) !void {
            var nonce: [12]u8 = undefined;
            @memcpy(nonce[0..4], self.iv[0..4]);
            @memcpy(nonce[4..12], explicit_nonce);
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        fn computeNonce(self: *Self, seq_num: u64) [12]u8 {
            var nonce = self.iv;
            // XOR the sequence number with the last 8 bytes of the IV
            const seq_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, seq_num));
            for (0..8) |i| {
                nonce[4 + i] ^= seq_bytes[i];
            }
            return nonce;
        }
    };
}

fn ChaChaState(comptime Crypto: type) type {
    return struct {
        key: [32]u8,
        iv: [12]u8,

        const Self = @This();
        const AEAD = Crypto.ChaCha20Poly1305;

        pub fn init(key: []const u8, iv: []const u8) !Self {
            if (key.len != 32) return error.InvalidKeyLength;
            if (iv.len != 12) return error.InvalidIvLength;

            var self: Self = undefined;
            @memcpy(&self.key, key);
            @memcpy(&self.iv, iv);
            return self;
        }

        pub fn encrypt(
            self: *Self,
            ciphertext: []u8,
            tag: *[16]u8,
            plaintext: []const u8,
            additional_data: []const u8,
            seq_num: u64,
        ) void {
            const nonce = self.computeNonce(seq_num);
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        /// TLS 1.2 encryption - ChaCha20-Poly1305 uses same format as TLS 1.3
        /// nonce = implicit_iv XOR padded_seq_num (not implicit || explicit)
        pub fn encryptTls12(
            self: *Self,
            ciphertext: []u8,
            tag: *[16]u8,
            plaintext: []const u8,
            additional_data: []const u8,
            explicit_nonce: *const [8]u8,
        ) void {
            // For ChaCha20-Poly1305 in TLS 1.2, the nonce is constructed differently
            // RFC 7905: nonce = fixed_iv XOR (0^32 || seq_num)
            var nonce: [12]u8 = self.iv;
            // XOR with explicit nonce (which is seq_num)
            for (0..8) |i| {
                nonce[4 + i] ^= explicit_nonce[i];
            }
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        pub fn decrypt(
            self: *Self,
            plaintext: []u8,
            ciphertext: []const u8,
            tag: [16]u8,
            additional_data: []const u8,
            seq_num: u64,
        ) !void {
            const nonce = self.computeNonce(seq_num);
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        /// TLS 1.2 decryption
        pub fn decryptTls12(
            self: *Self,
            plaintext: []u8,
            ciphertext: []const u8,
            tag: [16]u8,
            additional_data: []const u8,
            explicit_nonce: *const [8]u8,
        ) !void {
            var nonce: [12]u8 = self.iv;
            for (0..8) |i| {
                nonce[4 + i] ^= explicit_nonce[i];
            }
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        fn computeNonce(self: *Self, seq_num: u64) [12]u8 {
            var nonce = self.iv;
            const seq_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, seq_num));
            for (0..8) |i| {
                nonce[4 + i] ^= seq_bytes[i];
            }
            return nonce;
        }
    };
}

// ============================================================================
// Record Layer
// ============================================================================

pub const RecordError = error{
    BufferTooSmall,
    InvalidKeyLength,
    InvalidIvLength,
    UnsupportedCipherSuite,
    RecordTooLarge,
    DecryptionFailed,
    BadRecordMac,
    UnexpectedRecord,
};

/// TLS Record Layer
///
/// Handles reading/writing TLS records with optional encryption.
/// Generic over Socket and Crypto types.
pub fn RecordLayer(comptime Socket: type, comptime Crypto: type) type {
    return struct {
        socket: *Socket,
        read_cipher: CipherState(Crypto),
        write_cipher: CipherState(Crypto),
        read_seq: u64,
        write_seq: u64,
        version: ProtocolVersion,

        const Self = @This();

        pub fn init(socket: *Socket) Self {
            return Self{
                .socket = socket,
                .read_cipher = .none,
                .write_cipher = .none,
                .read_seq = 0,
                .write_seq = 0,
                .version = .tls_1_2, // Legacy version in record header
            };
        }

        /// Set the cipher for reading
        pub fn setReadCipher(self: *Self, cipher: CipherState(Crypto)) void {
            self.read_cipher = cipher;
            self.read_seq = 0;
        }

        /// Set the cipher for writing
        pub fn setWriteCipher(self: *Self, cipher: CipherState(Crypto)) void {
            self.write_cipher = cipher;
            self.write_seq = 0;
        }

        /// Write a plaintext record (encrypts if cipher is set)
        pub fn writeRecord(
            self: *Self,
            content_type: ContentType,
            plaintext: []const u8,
            buffer: []u8,
        ) !usize {
            if (plaintext.len > common.MAX_PLAINTEXT_LEN) {
                return error.RecordTooLarge;
            }

            switch (self.write_cipher) {
                .none => {
                    // Unencrypted record
                    const total_len = RecordHeader.SIZE + plaintext.len;
                    if (buffer.len < total_len) return error.BufferTooSmall;

                    const header = RecordHeader{
                        .content_type = content_type,
                        .legacy_version = self.version,
                        .length = @intCast(plaintext.len),
                    };
                    try header.serialize(buffer[0..RecordHeader.SIZE]);
                    @memcpy(buffer[RecordHeader.SIZE..][0..plaintext.len], plaintext);

                    _ = try self.socket.send(buffer[0..total_len]);
                    return total_len;
                },
                inline .aes_128_gcm, .aes_256_gcm, .chacha20_poly1305 => |*cipher| {
                    // TLS 1.2 vs TLS 1.3 have different encryption formats
                    if (self.version == .tls_1_3) {
                        // TLS 1.3: inner_plaintext = plaintext || content_type
                        // ciphertext = AEAD-Encrypt(inner_plaintext)
                        // content_type in header is always application_data
                        const inner_len = plaintext.len + 1;
                        const ciphertext_len = inner_len + 16;
                        const total_len = RecordHeader.SIZE + ciphertext_len;

                        if (buffer.len < total_len) return error.BufferTooSmall;

                        const header = RecordHeader{
                            .content_type = .application_data,
                            .legacy_version = .tls_1_2,
                            .length = @intCast(ciphertext_len),
                        };
                        try header.serialize(buffer[0..RecordHeader.SIZE]);

                        var inner_plaintext: [common.MAX_PLAINTEXT_LEN + 1]u8 = undefined;
                        @memcpy(inner_plaintext[0..plaintext.len], plaintext);
                        inner_plaintext[plaintext.len] = @intFromEnum(content_type);

                        const ad = buffer[0..RecordHeader.SIZE];

                        var tag: [16]u8 = undefined;
                        cipher.encrypt(
                            buffer[RecordHeader.SIZE..][0..inner_len],
                            &tag,
                            inner_plaintext[0..inner_len],
                            ad,
                            self.write_seq,
                        );
                        @memcpy(buffer[RecordHeader.SIZE + inner_len ..][0..16], &tag);

                        self.write_seq += 1;
                        _ = try self.socket.send(buffer[0..total_len]);
                        return total_len;
                    } else {
                        // TLS 1.2 GCM format (RFC 5288):
                        // Record = nonce_explicit(8) || ciphertext || tag(16)
                        // nonce = implicit_iv(4) || nonce_explicit(8)
                        // additional_data = seq_num(8) || type(1) || version(2) || length(2)
                        const explicit_nonce_len: usize = 8;
                        const record_len = explicit_nonce_len + plaintext.len + 16;
                        const total_len = RecordHeader.SIZE + record_len;

                        if (buffer.len < total_len) return error.BufferTooSmall;

                        // Record header with actual content type
                        const header = RecordHeader{
                            .content_type = content_type,
                            .legacy_version = self.version,
                            .length = @intCast(record_len),
                        };
                        try header.serialize(buffer[0..RecordHeader.SIZE]);

                        // Generate explicit nonce from sequence number
                        var explicit_nonce: [8]u8 = undefined;
                        std.mem.writeInt(u64, &explicit_nonce, self.write_seq, .big);
                        @memcpy(buffer[RecordHeader.SIZE..][0..8], &explicit_nonce);

                        // Build additional data: seq_num || type || version || plaintext_length
                        var ad: [13]u8 = undefined;
                        std.mem.writeInt(u64, ad[0..8], self.write_seq, .big);
                        ad[8] = @intFromEnum(content_type);
                        std.mem.writeInt(u16, ad[9..11], @intFromEnum(self.version), .big);
                        std.mem.writeInt(u16, ad[11..13], @intCast(plaintext.len), .big);

                        // Encrypt
                        var tag: [16]u8 = undefined;
                        cipher.encryptTls12(
                            buffer[RecordHeader.SIZE + 8 ..][0..plaintext.len],
                            &tag,
                            plaintext,
                            &ad,
                            &explicit_nonce,
                        );
                        @memcpy(buffer[RecordHeader.SIZE + 8 + plaintext.len ..][0..16], &tag);

                        self.write_seq += 1;
                        _ = try self.socket.send(buffer[0..total_len]);
                        return total_len;
                    }
                },
            }
        }

        /// Read and decrypt a record
        pub fn readRecord(
            self: *Self,
            buffer: []u8,
            plaintext_out: []u8,
        ) !struct { content_type: ContentType, length: usize } {
            // Read record header
            var header_buf: [RecordHeader.SIZE]u8 = undefined;
            var bytes_read: usize = 0;
            while (bytes_read < RecordHeader.SIZE) {
                const n = self.socket.recv(header_buf[bytes_read..]) catch |err| {
                    // Propagate timeout and other errors directly
                    return err;
                };
                if (n == 0) return error.UnexpectedRecord;
                bytes_read += n;
            }

            const header = try RecordHeader.parse(&header_buf);
            if (header.length > common.MAX_CIPHERTEXT_LEN) {
                return error.RecordTooLarge;
            }

            // Read record body
            if (buffer.len < header.length) return error.BufferTooSmall;
            bytes_read = 0;
            while (bytes_read < header.length) {
                const n = self.socket.recv(buffer[bytes_read..header.length]) catch |err| {
                    // Propagate timeout and other errors directly
                    return err;
                };
                if (n == 0) return error.UnexpectedRecord;
                bytes_read += n;
            }

            const record_body = buffer[0..header.length];

            // TLS 1.3: ChangeCipherSpec is always unencrypted for compatibility
            if (header.content_type == .change_cipher_spec) {
                if (plaintext_out.len < header.length) return error.BufferTooSmall;
                @memcpy(plaintext_out[0..header.length], record_body);
                return .{
                    .content_type = header.content_type,
                    .length = header.length,
                };
            }

            switch (self.read_cipher) {
                .none => {
                    // Unencrypted
                    if (plaintext_out.len < header.length) return error.BufferTooSmall;
                    @memcpy(plaintext_out[0..header.length], record_body);
                    return .{
                        .content_type = header.content_type,
                        .length = header.length,
                    };
                },
                inline .aes_128_gcm, .aes_256_gcm, .chacha20_poly1305 => |*cipher| {
                    if (self.version == .tls_1_3) {
                        // TLS 1.3: ciphertext || tag(16)
                        if (header.length < 17) return error.BadRecordMac;

                        const ciphertext_len = header.length - 16;
                        const ciphertext = record_body[0..ciphertext_len];
                        const tag = record_body[ciphertext_len..][0..16].*;

                        if (plaintext_out.len < ciphertext_len) return error.BufferTooSmall;

                        cipher.decrypt(
                            plaintext_out[0..ciphertext_len],
                            ciphertext,
                            tag,
                            &header_buf,
                            self.read_seq,
                        ) catch return error.BadRecordMac;

                        self.read_seq += 1;

                        // Remove padding and get inner content type
                        var inner_len = ciphertext_len;
                        while (inner_len > 0 and plaintext_out[inner_len - 1] == 0) {
                            inner_len -= 1;
                        }
                        if (inner_len == 0) return error.DecryptionFailed;

                        inner_len -= 1;
                        const inner_content_type: ContentType = @enumFromInt(plaintext_out[inner_len]);

                        return .{
                            .content_type = inner_content_type,
                            .length = inner_len,
                        };
                    } else {
                        // TLS 1.2: explicit_nonce(8) || ciphertext || tag(16)
                        if (header.length < 8 + 16 + 1) return error.BadRecordMac;

                        const explicit_nonce = record_body[0..8];
                        const ciphertext_len = header.length - 8 - 16;
                        const ciphertext = record_body[8..][0..ciphertext_len];
                        const tag = record_body[8 + ciphertext_len ..][0..16].*;

                        if (plaintext_out.len < ciphertext_len) return error.BufferTooSmall;

                        // Build additional data: seq_num || type || version || plaintext_length
                        var ad: [13]u8 = undefined;
                        std.mem.writeInt(u64, ad[0..8], self.read_seq, .big);
                        ad[8] = @intFromEnum(header.content_type);
                        std.mem.writeInt(u16, ad[9..11], @intFromEnum(header.legacy_version), .big);
                        std.mem.writeInt(u16, ad[11..13], @intCast(ciphertext_len), .big);

                        cipher.decryptTls12(
                            plaintext_out[0..ciphertext_len],
                            ciphertext,
                            tag,
                            &ad,
                            explicit_nonce,
                        ) catch return error.BadRecordMac;

                        self.read_seq += 1;

                        return .{
                            .content_type = header.content_type,
                            .length = ciphertext_len,
                        };
                    }
                },
            }
        }

        /// Send an alert
        pub fn sendAlert(
            self: *Self,
            level: AlertLevel,
            description: AlertDescription,
            buffer: []u8,
        ) !void {
            const alert_data = [_]u8{
                @intFromEnum(level),
                @intFromEnum(description),
            };
            _ = try self.writeRecord(.alert, &alert_data, buffer);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "RecordHeader parse and serialize" {
    const header = RecordHeader{
        .content_type = .handshake,
        .legacy_version = .tls_1_2,
        .length = 256,
    };

    var buf: [5]u8 = undefined;
    try header.serialize(&buf);

    const parsed = try RecordHeader.parse(&buf);
    try std.testing.expectEqual(header.content_type, parsed.content_type);
    try std.testing.expectEqual(header.legacy_version, parsed.legacy_version);
    try std.testing.expectEqual(header.length, parsed.length);
}

// Tests that use crypto need to import default crypto
const default_crypto = @import("crypto");

test "CipherState initialization" {
    const key_128: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = [_]u8{0} ** 12;

    const state = try CipherState(default_crypto.Suite).init(.TLS_AES_128_GCM_SHA256, &key_128, &iv);
    try std.testing.expect(state == .aes_128_gcm);
}

test "AES-128-GCM encrypt/decrypt round trip" {
    const key: [16]u8 = [_]u8{0x01} ** 16;
    const iv: [12]u8 = [_]u8{0x02} ** 12;
    const plaintext = "Hello, TLS Record Layer!";
    const ad = "additional data";

    var state = try AesGcmState(default_crypto.Suite, 16).init(&key, &iv);

    // Encrypt
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    // Decrypt
    var decrypted: [plaintext.len]u8 = undefined;
    try state.decrypt(&decrypted, &ciphertext, tag, ad, 0);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "AES-256-GCM encrypt/decrypt round trip" {
    const key: [32]u8 = [_]u8{0x03} ** 32;
    const iv: [12]u8 = [_]u8{0x04} ** 12;
    const plaintext = "Testing AES-256-GCM in record layer";
    const ad = "aad for test";

    var state = try AesGcmState(default_crypto.Suite, 32).init(&key, &iv);

    // Encrypt
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    // Decrypt
    var decrypted: [plaintext.len]u8 = undefined;
    try state.decrypt(&decrypted, &ciphertext, tag, ad, 0);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "ChaCha20-Poly1305 encrypt/decrypt round trip" {
    const key: [32]u8 = [_]u8{0x05} ** 32;
    const iv: [12]u8 = [_]u8{0x06} ** 12;
    const plaintext = "ChaCha20-Poly1305 record test";
    const ad = "associated data";

    var state = try ChaChaState(default_crypto.Suite).init(&key, &iv);

    // Encrypt
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    // Decrypt
    var decrypted: [plaintext.len]u8 = undefined;
    try state.decrypt(&decrypted, &ciphertext, tag, ad, 0);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "Nonce computation with sequence number" {
    const key: [16]u8 = [_]u8{0x00} ** 16;
    const iv: [12]u8 = [_]u8{
        0x00, 0x01, 0x02, 0x03, // First 4 bytes unchanged
        0x04, 0x05, 0x06, 0x07, // XORed with seq_num
        0x08, 0x09, 0x0a, 0x0b,
    };
    const plaintext = "Test";
    const ad = "";

    var state = try AesGcmState(default_crypto.Suite, 16).init(&key, &iv);

    // Encrypt with sequence 0
    var ct0: [4]u8 = undefined;
    var tag0: [16]u8 = undefined;
    state.encrypt(&ct0, &tag0, plaintext, ad, 0);

    // Encrypt with sequence 1 (should produce different ciphertext)
    var ct1: [4]u8 = undefined;
    var tag1: [16]u8 = undefined;
    state.encrypt(&ct1, &tag1, plaintext, ad, 1);

    // Ciphertexts should be different due to different nonces
    try std.testing.expect(!std.mem.eql(u8, &ct0, &ct1));
    try std.testing.expect(!std.mem.eql(u8, &tag0, &tag1));
}

test "Decryption with wrong sequence number fails" {
    const key: [16]u8 = [_]u8{0x07} ** 16;
    const iv: [12]u8 = [_]u8{0x08} ** 12;
    const plaintext = "Sequence number test";
    const ad = "aad";

    var state = try AesGcmState(default_crypto.Suite, 16).init(&key, &iv);

    // Encrypt with sequence 5
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 5);

    // Try to decrypt with wrong sequence number (should fail)
    var decrypted: [plaintext.len]u8 = undefined;
    const result = state.decrypt(&decrypted, &ciphertext, tag, ad, 6);
    try std.testing.expectError(error.AuthenticationFailed, result);

    // Decrypt with correct sequence number (should succeed)
    try state.decrypt(&decrypted, &ciphertext, tag, ad, 5);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "CipherState unsupported cipher suite" {
    const key: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = [_]u8{0} ** 12;

    // Use an unknown cipher suite value (0xFFFF is not a valid cipher suite)
    const unknown_suite: CipherSuite = @enumFromInt(0xFFFF);
    const result = CipherState(default_crypto.Suite).init(unknown_suite, &key, &iv);
    try std.testing.expectError(error.UnsupportedCipherSuite, result);
}

test "AesGcmState invalid key/iv length" {
    const short_key: [8]u8 = [_]u8{0} ** 8;
    const short_iv: [8]u8 = [_]u8{0} ** 8;
    const valid_key: [16]u8 = [_]u8{0} ** 16;
    const valid_iv: [12]u8 = [_]u8{0} ** 12;

    // Invalid key length
    const result1 = AesGcmState(default_crypto.Suite, 16).init(&short_key, &valid_iv);
    try std.testing.expectError(error.InvalidKeyLength, result1);

    // Invalid IV length
    const result2 = AesGcmState(default_crypto.Suite, 16).init(&valid_key, &short_iv);
    try std.testing.expectError(error.InvalidIvLength, result2);
}

// ============================================================================
// TLS 1.2 GCM Tests (RFC 5288)
// ============================================================================

test "TLS 1.2 AES-128-GCM encrypt/decrypt round trip" {
    // RFC 5288: GCMNonce = salt[4] || nonce_explicit[8]
    // salt = implicit IV from key derivation (first 4 bytes of 12-byte IV)
    // nonce_explicit = sequence number (8 bytes)

    const key: [16]u8 = [_]u8{0x01} ** 16;
    // For TLS 1.2, only first 4 bytes are the implicit IV (salt)
    var iv: [12]u8 = [_]u8{0} ** 12;
    iv[0] = 0xAA;
    iv[1] = 0xBB;
    iv[2] = 0xCC;
    iv[3] = 0xDD;

    var state = try AesGcmState(default_crypto.Suite, 16).init(&key, &iv);

    const plaintext = "TLS 1.2 GCM test message";

    // Build explicit nonce from sequence number 0
    var explicit_nonce: [8]u8 = undefined;
    std.mem.writeInt(u64, &explicit_nonce, 0, .big);

    // Build additional_data: seq_num(8) || type(1) || version(2) || length(2)
    // RFC 5246 Section 6.2.3.3
    var ad: [13]u8 = undefined;
    std.mem.writeInt(u64, ad[0..8], 0, .big); // seq_num = 0
    ad[8] = @intFromEnum(ContentType.application_data); // type
    std.mem.writeInt(u16, ad[9..11], @intFromEnum(ProtocolVersion.tls_1_2), .big); // version
    std.mem.writeInt(u16, ad[11..13], @intCast(plaintext.len), .big); // plaintext length

    // Encrypt
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encryptTls12(&ciphertext, &tag, plaintext, &ad, &explicit_nonce);

    // Decrypt
    var decrypted: [plaintext.len]u8 = undefined;
    try state.decryptTls12(&decrypted, &ciphertext, tag, &ad, &explicit_nonce);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "TLS 1.2 AES-256-GCM encrypt/decrypt round trip" {
    const key: [32]u8 = [_]u8{0x02} ** 32;
    var iv: [12]u8 = [_]u8{0} ** 12;
    iv[0] = 0x11;
    iv[1] = 0x22;
    iv[2] = 0x33;
    iv[3] = 0x44;

    var state = try AesGcmState(default_crypto.Suite, 32).init(&key, &iv);

    const plaintext = "TLS 1.2 AES-256-GCM test";

    var explicit_nonce: [8]u8 = undefined;
    std.mem.writeInt(u64, &explicit_nonce, 5, .big); // seq_num = 5

    var ad: [13]u8 = undefined;
    std.mem.writeInt(u64, ad[0..8], 5, .big);
    ad[8] = @intFromEnum(ContentType.handshake);
    std.mem.writeInt(u16, ad[9..11], @intFromEnum(ProtocolVersion.tls_1_2), .big);
    std.mem.writeInt(u16, ad[11..13], @intCast(plaintext.len), .big);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encryptTls12(&ciphertext, &tag, plaintext, &ad, &explicit_nonce);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decryptTls12(&decrypted, &ciphertext, tag, &ad, &explicit_nonce);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "TLS 1.2 GCM nonce construction" {
    // Verify nonce = implicit_iv[0..4] || explicit_nonce[0..8]
    const key: [16]u8 = [_]u8{0} ** 16;
    var iv: [12]u8 = undefined;
    iv[0] = 0xAA;
    iv[1] = 0xBB;
    iv[2] = 0xCC;
    iv[3] = 0xDD;
    @memset(iv[4..12], 0); // Rest doesn't matter for TLS 1.2

    var state = try AesGcmState(default_crypto.Suite, 16).init(&key, &iv);

    const plaintext = "Test";
    var ad: [13]u8 = [_]u8{0} ** 13;

    // Two different explicit nonces should produce different ciphertexts
    var nonce1: [8]u8 = [_]u8{0} ** 8;
    nonce1[7] = 0x01;
    var nonce2: [8]u8 = [_]u8{0} ** 8;
    nonce2[7] = 0x02;

    var ct1: [4]u8 = undefined;
    var tag1: [16]u8 = undefined;
    state.encryptTls12(&ct1, &tag1, plaintext, &ad, &nonce1);

    var ct2: [4]u8 = undefined;
    var tag2: [16]u8 = undefined;
    state.encryptTls12(&ct2, &tag2, plaintext, &ad, &nonce2);

    // Different nonces should produce different ciphertexts
    try std.testing.expect(!std.mem.eql(u8, &ct1, &ct2));
    try std.testing.expect(!std.mem.eql(u8, &tag1, &tag2));
}

test "TLS 1.2 GCM wrong AD fails" {
    const key: [16]u8 = [_]u8{0x03} ** 16;
    var iv: [12]u8 = [_]u8{0} ** 12;
    iv[0] = 0x55;
    iv[1] = 0x66;
    iv[2] = 0x77;
    iv[3] = 0x88;

    var state = try AesGcmState(default_crypto.Suite, 16).init(&key, &iv);

    const plaintext = "Test AD verification";
    var explicit_nonce: [8]u8 = [_]u8{0} ** 8;

    var ad_encrypt: [13]u8 = undefined;
    std.mem.writeInt(u64, ad_encrypt[0..8], 0, .big);
    ad_encrypt[8] = @intFromEnum(ContentType.application_data);
    std.mem.writeInt(u16, ad_encrypt[9..11], @intFromEnum(ProtocolVersion.tls_1_2), .big);
    std.mem.writeInt(u16, ad_encrypt[11..13], @intCast(plaintext.len), .big);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encryptTls12(&ciphertext, &tag, plaintext, &ad_encrypt, &explicit_nonce);

    // Try to decrypt with wrong AD (different seq_num)
    var ad_decrypt: [13]u8 = undefined;
    std.mem.writeInt(u64, ad_decrypt[0..8], 1, .big); // Wrong seq_num!
    ad_decrypt[8] = @intFromEnum(ContentType.application_data);
    std.mem.writeInt(u16, ad_decrypt[9..11], @intFromEnum(ProtocolVersion.tls_1_2), .big);
    std.mem.writeInt(u16, ad_decrypt[11..13], @intCast(plaintext.len), .big);

    var decrypted: [plaintext.len]u8 = undefined;
    const result = state.decryptTls12(&decrypted, &ciphertext, tag, &ad_decrypt, &explicit_nonce);
    try std.testing.expectError(error.AuthenticationFailed, result);
}

test "TLS 1.2 ChaCha20-Poly1305 encrypt/decrypt round trip" {
    // RFC 7905: ChaCha20-Poly1305 nonce = fixed_iv XOR (0^32 || seq_num)
    const key: [32]u8 = [_]u8{0x04} ** 32;
    const iv: [12]u8 = [_]u8{0x05} ** 12;

    var state = try ChaChaState(default_crypto.Suite).init(&key, &iv);

    const plaintext = "TLS 1.2 ChaCha20 test";

    var explicit_nonce: [8]u8 = undefined;
    std.mem.writeInt(u64, &explicit_nonce, 0, .big);

    var ad: [13]u8 = undefined;
    std.mem.writeInt(u64, ad[0..8], 0, .big);
    ad[8] = @intFromEnum(ContentType.application_data);
    std.mem.writeInt(u16, ad[9..11], @intFromEnum(ProtocolVersion.tls_1_2), .big);
    std.mem.writeInt(u16, ad[11..13], @intCast(plaintext.len), .big);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encryptTls12(&ciphertext, &tag, plaintext, &ad, &explicit_nonce);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decryptTls12(&decrypted, &ciphertext, tag, &ad, &explicit_nonce);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "TLS 1.2 Finished message encryption/decryption" {
    // Simulate encrypting/decrypting a TLS 1.2 Finished message
    const key: [16]u8 = [_]u8{0x06} ** 16;
    var iv: [12]u8 = [_]u8{0} ** 12;
    iv[0] = 0x12;
    iv[1] = 0x34;
    iv[2] = 0x56;
    iv[3] = 0x78;

    var state = try AesGcmState(default_crypto.Suite, 16).init(&key, &iv);

    // Finished message: handshake type (1) + length (3) + verify_data (12) = 16 bytes
    const finished_msg = [_]u8{0x14} ++ // Finished type
        [_]u8{ 0x00, 0x00, 0x0C } ++ // Length = 12
        [_]u8{0xAA} ** 12; // verify_data

    var explicit_nonce: [8]u8 = undefined;
    std.mem.writeInt(u64, &explicit_nonce, 0, .big);

    // AD for handshake message
    var ad: [13]u8 = undefined;
    std.mem.writeInt(u64, ad[0..8], 0, .big); // seq_num
    ad[8] = @intFromEnum(ContentType.handshake); // type = handshake
    std.mem.writeInt(u16, ad[9..11], @intFromEnum(ProtocolVersion.tls_1_2), .big);
    std.mem.writeInt(u16, ad[11..13], @intCast(finished_msg.len), .big);

    var ciphertext: [finished_msg.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encryptTls12(&ciphertext, &tag, &finished_msg, &ad, &explicit_nonce);

    var decrypted: [finished_msg.len]u8 = undefined;
    try state.decryptTls12(&decrypted, &ciphertext, tag, &ad, &explicit_nonce);

    try std.testing.expectEqualSlices(u8, &finished_msg, &decrypted);

    // Verify the first byte is the Finished type
    try std.testing.expectEqual(@as(u8, 0x14), decrypted[0]);
}
