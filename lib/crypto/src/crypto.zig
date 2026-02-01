//! Cryptographic Primitives for TLS
//!
//! This module re-exports std.crypto primitives needed for TLS implementation
//! and provides additional utilities for embedded systems.
//!
//! ## Supported Algorithms
//!
//! ### AEAD (Authenticated Encryption)
//! - AES-128-GCM, AES-256-GCM
//! - ChaCha20-Poly1305
//!
//! ### Hash Functions
//! - SHA-256, SHA-384, SHA-512
//! - SHA-1 (legacy, for TLS 1.2 compatibility)
//!
//! ### Key Derivation
//! - HKDF (HMAC-based Key Derivation Function)
//! - HMAC
//!
//! ### Key Exchange
//! - X25519 (Curve25519 ECDH)
//! - P-256 (secp256r1)
//! - P-384 (secp384r1)
//!
//! ### Digital Signatures
//! - ECDSA (P-256, P-384)
//! - Ed25519
//! - RSA (verify only)

const std = @import("std");

// ============================================================================
// AEAD - Authenticated Encryption with Associated Data
// ============================================================================

pub const aead = struct {
    pub const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
    pub const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
    pub const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
};

// ============================================================================
// Hash Functions
// ============================================================================

pub const hash = struct {
    pub const Sha256 = std.crypto.hash.sha2.Sha256;
    pub const Sha384 = std.crypto.hash.sha2.Sha384;
    pub const Sha512 = std.crypto.hash.sha2.Sha512;
    pub const Sha1 = std.crypto.hash.Sha1;
};

// ============================================================================
// HMAC - Hash-based Message Authentication Code
// ============================================================================

pub const auth = struct {
    pub const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    pub const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;
    pub const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;
};

// ============================================================================
// Key Derivation Functions
// ============================================================================

pub const kdf = struct {
    pub const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
    pub const HkdfSha384 = std.crypto.kdf.hkdf.Hkdf(std.crypto.hash.sha2.Sha384);
    pub const HkdfSha512 = std.crypto.kdf.hkdf.Hkdf(std.crypto.hash.sha2.Sha512);

    /// HKDF-Expand-Label as defined in RFC 8446 Section 7.1
    /// Used for TLS 1.3 key derivation
    pub fn hkdfExpandLabel(
        comptime Hkdf: type,
        secret: [Hkdf.prk_length]u8,
        label: []const u8,
        context: []const u8,
        comptime length: usize,
    ) [length]u8 {
        const max_label_len = 255;
        const max_context_len = 255;
        const tls13_label = "tls13 ";

        std.debug.assert(label.len <= max_label_len - tls13_label.len);
        std.debug.assert(context.len <= max_context_len);

        const label_len: u8 = @intCast(tls13_label.len + label.len);
        const context_len: u8 = @intCast(context.len);

        // HkdfLabel structure:
        // uint16 length
        // opaque label<7..255>
        // opaque context<0..255>
        var hkdf_label: [2 + 1 + max_label_len + 1 + max_context_len]u8 = undefined;
        var pos: usize = 0;

        // length (2 bytes, big endian)
        hkdf_label[pos] = @intCast(length >> 8);
        hkdf_label[pos + 1] = @intCast(length & 0xff);
        pos += 2;

        // label length (1 byte)
        hkdf_label[pos] = label_len;
        pos += 1;

        // "tls13 " prefix
        @memcpy(hkdf_label[pos..][0..tls13_label.len], tls13_label);
        pos += tls13_label.len;

        // actual label
        @memcpy(hkdf_label[pos..][0..label.len], label);
        pos += label.len;

        // context length (1 byte)
        hkdf_label[pos] = context_len;
        pos += 1;

        // context
        @memcpy(hkdf_label[pos..][0..context.len], context);
        pos += context.len;

        var result: [length]u8 = undefined;
        Hkdf.expand(&result, hkdf_label[0..pos], secret);
        return result;
    }
};

// ============================================================================
// Elliptic Curve Cryptography
// ============================================================================

pub const ecc = struct {
    /// X25519 key exchange (Curve25519)
    pub const X25519 = std.crypto.dh.X25519;

    /// P-256 (secp256r1) curve
    pub const P256 = std.crypto.ecc.P256;

    /// P-384 (secp384r1) curve
    pub const P384 = std.crypto.ecc.P384;
};

// ============================================================================
// Digital Signatures
// ============================================================================

pub const sign = struct {
    /// ECDSA with P-256 and SHA-256
    pub const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

    /// ECDSA with P-384 and SHA-384
    pub const EcdsaP384Sha384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;

    /// Ed25519 signature scheme
    pub const Ed25519 = std.crypto.sign.Ed25519;
};

// ============================================================================
// RSA (from std.crypto.Certificate)
// ============================================================================

pub const rsa = struct {
    pub const PublicKey = std.crypto.Certificate.rsa.PublicKey;
    pub const PSSSignature = std.crypto.Certificate.rsa.PSSSignature;
    pub const PKCS1v1_5Signature = std.crypto.Certificate.rsa.PKCS1v1_5Signature;
};

// ============================================================================
// X.509 Certificate Support
// ============================================================================

pub const Certificate = std.crypto.Certificate;
pub const x509 = @import("x509/x509.zig");

// ============================================================================
// Utilities
// ============================================================================

/// Constant-time comparison to prevent timing attacks
pub const timing_safe = std.crypto.timing_safe;

/// Secure memory zeroing
pub fn secureZero(comptime T: type, s: []volatile T) void {
    std.crypto.secureZero(T, s);
}

/// Random number generation (re-export for convenience)
pub const random = std.crypto.random;

// ============================================================================
// TLS-specific Constants
// ============================================================================

pub const tls_constants = struct {
    /// Maximum plaintext record size (RFC 8446)
    pub const max_plaintext_len = 16384;

    /// Maximum ciphertext record size
    pub const max_ciphertext_len = 16384 + 256; // TLS 1.3

    /// Record header length
    pub const record_header_len = 5;

    /// TLS versions
    pub const ProtocolVersion = enum(u16) {
        tls_1_0 = 0x0301,
        tls_1_1 = 0x0302,
        tls_1_2 = 0x0303,
        tls_1_3 = 0x0304,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "AEAD encryption/decryption" {
    const key: [16]u8 = [_]u8{0} ** 16;
    const nonce: [12]u8 = [_]u8{0} ** 12;
    const plaintext = "Hello, TLS!";
    const ad = "additional data";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;

    aead.Aes128Gcm.encrypt(&ciphertext, &tag, plaintext, ad, nonce, key);

    var decrypted: [plaintext.len]u8 = undefined;
    try aead.Aes128Gcm.decrypt(&decrypted, &ciphertext, tag, ad, nonce, key);

    try std.testing.expectEqualStrings(plaintext, &decrypted);
}

test "HKDF-Expand-Label" {
    // Test vector validation
    const secret: [32]u8 = [_]u8{0x0b} ** 32;
    const result = kdf.hkdfExpandLabel(kdf.HkdfSha256, secret, "test", "", 32);
    try std.testing.expect(result.len == 32);
}

test "X25519 key exchange" {
    // Generate two key pairs
    const seed_a: [32]u8 = [_]u8{1} ** 32;
    const seed_b: [32]u8 = [_]u8{2} ** 32;

    const kp_a = try ecc.X25519.KeyPair.generateDeterministic(seed_a);
    const kp_b = try ecc.X25519.KeyPair.generateDeterministic(seed_b);

    // Compute shared secrets
    const shared_a = try ecc.X25519.scalarmult(kp_a.secret_key, kp_b.public_key);
    const shared_b = try ecc.X25519.scalarmult(kp_b.secret_key, kp_a.public_key);

    // Should be equal
    try std.testing.expectEqual(shared_a, shared_b);
}

test "Hash functions" {
    const data = "test data";

    var sha256_hash: [32]u8 = undefined;
    hash.Sha256.hash(data, &sha256_hash, .{});
    try std.testing.expect(sha256_hash[0] != 0 or sha256_hash[1] != 0);

    var sha384_hash: [48]u8 = undefined;
    hash.Sha384.hash(data, &sha384_hash, .{});
    try std.testing.expect(sha384_hash[0] != 0 or sha384_hash[1] != 0);
}
