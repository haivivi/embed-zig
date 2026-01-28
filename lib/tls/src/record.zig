//! TLS Record Layer
//!
//! Implements the TLS record protocol (RFC 8446 Section 5).
//! Handles encryption/decryption of TLS records.

const std = @import("std");
const crypto = @import("crypto");
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
// Record Encryption/Decryption
// ============================================================================

/// Cipher state for encrypting/decrypting records
pub const CipherState = union(enum) {
    /// No encryption (initial state)
    none,
    /// AES-128-GCM
    aes_128_gcm: AesGcmState(16),
    /// AES-256-GCM
    aes_256_gcm: AesGcmState(32),
    /// ChaCha20-Poly1305
    chacha20_poly1305: ChaChaState,

    pub fn init(suite: CipherSuite, key: []const u8, iv: []const u8) !CipherState {
        return switch (suite) {
            .TLS_AES_128_GCM_SHA256,
            .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
            .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
            => .{ .aes_128_gcm = try AesGcmState(16).init(key, iv) },

            .TLS_AES_256_GCM_SHA384,
            .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
            .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
            => .{ .aes_256_gcm = try AesGcmState(32).init(key, iv) },

            .TLS_CHACHA20_POLY1305_SHA256,
            .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
            .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
            => .{ .chacha20_poly1305 = try ChaChaState.init(key, iv) },

            else => return error.UnsupportedCipherSuite,
        };
    }
};

fn AesGcmState(comptime key_len: usize) type {
    return struct {
        key: [key_len]u8,
        iv: [12]u8,

        const Self = @This();
        const AEAD = if (key_len == 16)
            crypto.aead.Aes128Gcm
        else
            crypto.aead.Aes256Gcm;

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
            AEAD.encrypt(ciphertext, tag, plaintext, additional_data, nonce, self.key);
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
            try AEAD.decrypt(plaintext, ciphertext, tag, additional_data, nonce, self.key);
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

const ChaChaState = struct {
    key: [32]u8,
    iv: [12]u8,

    const AEAD = crypto.aead.ChaCha20Poly1305;

    pub fn init(key: []const u8, iv: []const u8) !ChaChaState {
        if (key.len != 32) return error.InvalidKeyLength;
        if (iv.len != 12) return error.InvalidIvLength;

        var self: ChaChaState = undefined;
        @memcpy(&self.key, key);
        @memcpy(&self.iv, iv);
        return self;
    }

    pub fn encrypt(
        self: *ChaChaState,
        ciphertext: []u8,
        tag: *[16]u8,
        plaintext: []const u8,
        additional_data: []const u8,
        seq_num: u64,
    ) void {
        const nonce = self.computeNonce(seq_num);
        AEAD.encrypt(ciphertext, tag, plaintext, additional_data, nonce, self.key);
    }

    pub fn decrypt(
        self: *ChaChaState,
        plaintext: []u8,
        ciphertext: []const u8,
        tag: [16]u8,
        additional_data: []const u8,
        seq_num: u64,
    ) !void {
        const nonce = self.computeNonce(seq_num);
        try AEAD.decrypt(plaintext, ciphertext, tag, additional_data, nonce, self.key);
    }

    fn computeNonce(self: *ChaChaState, seq_num: u64) [12]u8 {
        var nonce = self.iv;
        const seq_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, seq_num));
        for (0..8) |i| {
            nonce[4 + i] ^= seq_bytes[i];
        }
        return nonce;
    }
};

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
pub fn RecordLayer(comptime Socket: type) type {
    return struct {
        socket: *Socket,
        read_cipher: CipherState,
        write_cipher: CipherState,
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
        pub fn setReadCipher(self: *Self, cipher: CipherState) void {
            self.read_cipher = cipher;
            self.read_seq = 0;
        }

        /// Set the cipher for writing
        pub fn setWriteCipher(self: *Self, cipher: CipherState) void {
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
                    // Encrypted record (TLS 1.3 style)
                    // inner_plaintext = plaintext || content_type (1 byte)
                    // ciphertext = AEAD-Encrypt(inner_plaintext)
                    const inner_len = plaintext.len + 1; // +1 for inner content type
                    const ciphertext_len = inner_len + 16; // +16 for auth tag
                    const total_len = RecordHeader.SIZE + ciphertext_len;

                    if (buffer.len < total_len) return error.BufferTooSmall;

                    // Build record header (content type is always application_data for encrypted)
                    const header = RecordHeader{
                        .content_type = .application_data,
                        .legacy_version = self.version,
                        .length = @intCast(ciphertext_len),
                    };
                    try header.serialize(buffer[0..RecordHeader.SIZE]);

                    // Build inner plaintext
                    var inner_plaintext: [common.MAX_PLAINTEXT_LEN + 1]u8 = undefined;
                    @memcpy(inner_plaintext[0..plaintext.len], plaintext);
                    inner_plaintext[plaintext.len] = @intFromEnum(content_type);

                    // Additional data is the record header
                    const ad = buffer[0..RecordHeader.SIZE];

                    // Encrypt
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
                const n = try self.socket.recv(header_buf[bytes_read..]);
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
                const n = try self.socket.recv(buffer[bytes_read..header.length]);
                if (n == 0) return error.UnexpectedRecord;
                bytes_read += n;
            }

            const record_body = buffer[0..header.length];

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
                    // Encrypted record
                    if (header.length < 17) return error.BadRecordMac; // At least 1 byte + 16 tag

                    const ciphertext_len = header.length - 16;
                    const ciphertext = record_body[0..ciphertext_len];
                    const tag = record_body[ciphertext_len..][0..16].*;

                    if (plaintext_out.len < ciphertext_len) return error.BufferTooSmall;

                    // Additional data is the record header
                    cipher.decrypt(
                        plaintext_out[0..ciphertext_len],
                        ciphertext,
                        tag,
                        &header_buf,
                        self.read_seq,
                    ) catch return error.BadRecordMac;

                    self.read_seq += 1;

                    // Remove trailing zeros and get inner content type
                    var inner_len = ciphertext_len;
                    while (inner_len > 0 and plaintext_out[inner_len - 1] == 0) {
                        inner_len -= 1;
                    }
                    if (inner_len == 0) return error.DecryptionFailed;

                    inner_len -= 1; // Remove content type byte
                    const inner_content_type: ContentType = @enumFromInt(plaintext_out[inner_len]);

                    return .{
                        .content_type = inner_content_type,
                        .length = inner_len,
                    };
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

test "CipherState initialization" {
    const key_128: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = [_]u8{0} ** 12;

    const state = try CipherState.init(.TLS_AES_128_GCM_SHA256, &key_128, &iv);
    try std.testing.expect(state == .aes_128_gcm);
}
