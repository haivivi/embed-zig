//! Crypto Suite - ESP32 mbedTLS Implementation
//!
//! Hardware-accelerated cryptographic primitives using mbedTLS.
//! This implementation uses ESP32's hardware acceleration where available.
//!
//! Components:
//! - Hash (SHA256/384/512): mbedTLS (software, HW accel disabled due to DMA issues)
//! - AEAD (AES-GCM, ChaCha20): mbedTLS (AES uses HW acceleration)
//! - KDF (HKDF): mbedTLS via C helper
//! - MAC (HMAC): mbedTLS
//! - Key Exchange (X25519, P256, P384): mbedTLS via C helpers
//! - RNG: ESP32 hardware true random number generator
//!
//! Note: X25519/P256/P384 use C helpers because mbedTLS 3.x made ecdh_context
//! opaque. X25519 uses HACL* Curve25519 from Everest library.
//! See lib/esp/src/idf/mbed_tls/*.c for helper implementations.
//!
//! Usage:
//! ```zig
//! const Crypto = @import("esp").impl.crypto.Suite;
//! const TlsClient = tls.Client(Socket, Crypto);
//! ```

const std = @import("std");
const idf = @import("idf");
const mbed = idf.mbed_tls;

// mbedTLS C helper wrappers
// These wrap opaque mbedTLS structures with simple byte-array interfaces
const mbed_x25519 = idf.mbed_tls.x25519_helper;
const mbed_p256 = idf.mbed_tls.p256_helper;
const mbed_p384 = idf.mbed_tls.p384_helper;
const mbed_aes_gcm = idf.mbed_tls.aes_gcm_helper;
const mbed_hkdf = idf.mbed_tls.hkdf_helper;

// ============================================================================
// Hash Functions
// ============================================================================

/// SHA-256 using mbedTLS (hardware accelerated on ESP32)
pub const Sha256 = struct {
    pub const digest_length = 32;
    pub const block_length = 64;

    ctx: mbed.sha256_context,

    pub fn init() Sha256 {
        var self: Sha256 = undefined;
        mbed.sha256_init(&self.ctx);
        _ = mbed.sha256_starts(&self.ctx, 0); // 0 = SHA-256 (not SHA-224)
        return self;
    }

    pub fn update(self: *Sha256, data: []const u8) void {
        _ = mbed.sha256_update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *Sha256) [digest_length]u8 {
        var out: [digest_length]u8 = undefined;
        _ = mbed.sha256_finish(&self.ctx, &out);
        mbed.sha256_free(&self.ctx);
        return out;
    }

    /// One-shot hash
    pub fn hash(data: []const u8, out: *[digest_length]u8, opts: anytype) void {
        _ = opts;
        _ = mbed.sha256_hash(data.ptr, data.len, out, 0);
    }
};

/// SHA-384 using mbedTLS
pub const Sha384 = struct {
    pub const digest_length = 48;
    pub const block_length = 128;

    ctx: mbed.sha512_context,

    pub fn init() Sha384 {
        var self: Sha384 = undefined;
        mbed.sha512_init(&self.ctx);
        _ = mbed.sha512_starts(&self.ctx, 1); // 1 = SHA-384
        return self;
    }

    pub fn update(self: *Sha384, data: []const u8) void {
        _ = mbed.sha512_update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *Sha384) [digest_length]u8 {
        var out: [64]u8 = undefined; // SHA-512 context outputs 64 bytes
        _ = mbed.sha512_finish(&self.ctx, &out);
        mbed.sha512_free(&self.ctx);
        return out[0..digest_length].*;
    }

    pub fn hash(data: []const u8, out: *[digest_length]u8, opts: anytype) void {
        _ = opts;
        var full_out: [64]u8 = undefined;
        _ = mbed.sha512_hash(data.ptr, data.len, &full_out, 1);
        out.* = full_out[0..digest_length].*;
    }
};

/// SHA-512 using mbedTLS
pub const Sha512 = struct {
    pub const digest_length = 64;
    pub const block_length = 128;

    ctx: mbed.sha512_context,

    pub fn init() Sha512 {
        var self: Sha512 = undefined;
        mbed.sha512_init(&self.ctx);
        _ = mbed.sha512_starts(&self.ctx, 0); // 0 = SHA-512
        return self;
    }

    pub fn update(self: *Sha512, data: []const u8) void {
        _ = mbed.sha512_update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *Sha512) [digest_length]u8 {
        var out: [digest_length]u8 = undefined;
        _ = mbed.sha512_finish(&self.ctx, &out);
        mbed.sha512_free(&self.ctx);
        return out;
    }

    pub fn hash(data: []const u8, out: *[digest_length]u8, opts: anytype) void {
        _ = opts;
        _ = mbed.sha512_hash(data.ptr, data.len, out, 0);
    }
};

/// SHA-1 using mbedTLS (legacy, for TLS 1.2)
pub const Sha1 = struct {
    pub const digest_length = 20;
    pub const block_length = 64;

    ctx: mbed.sha1_context,

    pub fn init() Sha1 {
        var self: Sha1 = undefined;
        mbed.sha1_init(&self.ctx);
        _ = mbed.sha1_starts(&self.ctx);
        return self;
    }

    pub fn update(self: *Sha1, data: []const u8) void {
        _ = mbed.sha1_update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *Sha1) [digest_length]u8 {
        var out: [digest_length]u8 = undefined;
        _ = mbed.sha1_finish(&self.ctx, &out);
        mbed.sha1_free(&self.ctx);
        return out;
    }

    pub fn hash(data: []const u8, out: *[digest_length]u8, opts: anytype) void {
        _ = opts;
        _ = mbed.sha1_hash(data.ptr, data.len, out);
    }
};

// ============================================================================
// AEAD - AES-GCM (hardware accelerated on ESP32)
// ============================================================================

/// AES-128-GCM using C helper (hardware accelerated on ESP32)
pub const Aes128Gcm = struct {
    pub const key_length = 16;
    pub const nonce_length = 12;
    pub const tag_length = 16;

    /// Static encrypt - one-shot API
    pub fn encryptStatic(
        ciphertext: []u8,
        tag: *[tag_length]u8,
        plaintext: []const u8,
        aad: []const u8,
        nonce: [nonce_length]u8,
        key: [key_length]u8,
    ) void {
        mbed_aes_gcm.Aes128.encrypt(ciphertext, tag, plaintext, aad, nonce, key);
    }

    /// Static decrypt - one-shot API
    pub fn decryptStatic(
        plaintext: []u8,
        ciphertext: []const u8,
        tag: [tag_length]u8,
        aad: []const u8,
        nonce: [nonce_length]u8,
        key: [key_length]u8,
    ) error{AuthenticationFailed}!void {
        mbed_aes_gcm.Aes128.decrypt(plaintext, ciphertext, tag, aad, nonce, key) catch |err| {
            switch (err) {
                error.AuthenticationFailed => return error.AuthenticationFailed,
                error.CryptoError => return error.AuthenticationFailed,
            }
        };
    }
};

/// AES-256-GCM using C helper (hardware accelerated on ESP32)
pub const Aes256Gcm = struct {
    pub const key_length = 32;
    pub const nonce_length = 12;
    pub const tag_length = 16;

    pub fn encryptStatic(
        ciphertext: []u8,
        tag: *[tag_length]u8,
        plaintext: []const u8,
        aad: []const u8,
        nonce: [nonce_length]u8,
        key: [key_length]u8,
    ) void {
        mbed_aes_gcm.Aes256.encrypt(ciphertext, tag, plaintext, aad, nonce, key);
    }

    pub fn decryptStatic(
        plaintext: []u8,
        ciphertext: []const u8,
        tag: [tag_length]u8,
        aad: []const u8,
        nonce: [nonce_length]u8,
        key: [key_length]u8,
    ) error{AuthenticationFailed}!void {
        mbed_aes_gcm.Aes256.decrypt(plaintext, ciphertext, tag, aad, nonce, key) catch |err| {
            switch (err) {
                error.AuthenticationFailed => return error.AuthenticationFailed,
                error.CryptoError => return error.AuthenticationFailed,
            }
        };
    }
};

// ============================================================================
// AEAD - ChaCha20-Poly1305 (DISABLED to reduce binary size)
// ============================================================================

/// ChaCha20-Poly1305 stub - disabled to reduce binary size
/// Only AES-GCM cipher suites are supported in this minimal build.
pub const ChaCha20Poly1305 = struct {
    pub const key_length = 32;
    pub const nonce_length = 12;
    pub const tag_length = 16;

    pub fn encryptStatic(
        _: []u8,
        _: *[tag_length]u8,
        _: []const u8,
        _: []const u8,
        _: [nonce_length]u8,
        _: [key_length]u8,
    ) void {
        @panic("ChaCha20-Poly1305 disabled in minimal build");
    }

    pub fn decryptStatic(
        _: []u8,
        _: []const u8,
        _: [tag_length]u8,
        _: []const u8,
        _: [nonce_length]u8,
        _: [key_length]u8,
    ) error{AuthenticationFailed}!void {
        @panic("ChaCha20-Poly1305 disabled in minimal build");
    }
};

// ============================================================================
// Key Exchange - X25519 (via HACL* Curve25519 from Everest)
// ============================================================================

/// X25519 key exchange using HACL* Curve25519 via C helper
///
/// Uses the verified HACL* implementation from mbedTLS Everest 3rdparty.
/// See: lib/esp/src/idf/mbed_tls/x25519_helper.c
pub const X25519 = struct {
    pub const secret_length = 32;
    pub const public_length = 32;
    pub const shared_length = 32;
    pub const seed_length = 32;

    pub const KeyPair = struct {
        secret_key: [secret_length]u8,
        public_key: [public_length]u8,

        pub fn generateDeterministic(seed: [seed_length]u8) mbed_x25519.Error!KeyPair {
            const kp = try mbed_x25519.KeyPair.generateDeterministic(seed);
            return KeyPair{
                .secret_key = kp.secret_key,
                .public_key = kp.public_key,
            };
        }
    };

    pub fn scalarmult(secret_key: [secret_length]u8, public_key: [public_length]u8) mbed_x25519.Error![32]u8 {
        return mbed_x25519.scalarmult(secret_key, public_key);
    }
};

// ============================================================================
// Key Exchange - P-256/P-384 (via mbedTLS C helpers)
// ============================================================================

/// P-256 (secp256r1) key exchange using mbedTLS via C helper
/// See: lib/esp/src/idf/mbed_tls/p256_helper.c
pub const P256 = struct {
    pub const secret_length = 32;
    pub const public_length = 65; // Uncompressed SEC1: 04 || x || y
    pub const shared_length = 32;
    pub const seed_length = 32;
    pub const scalar_length = 32;

    pub const KeyPair = struct {
        secret_key: [secret_length]u8,
        public_key: [public_length]u8,

        pub fn generateDeterministic(seed: [seed_length]u8) mbed_p256.Error!KeyPair {
            const kp = try mbed_p256.KeyPair.generateDeterministic(seed);
            return KeyPair{
                .secret_key = kp.secret_key,
                .public_key = kp.public_key,
            };
        }
    };

    /// Compute public key from secret key (for TLS handshake)
    pub fn computePublicKey(secret_key: [secret_length]u8) mbed_p256.Error![public_length]u8 {
        return mbed_p256.computePublic(secret_key);
    }

    /// Perform ECDH key exchange
    pub fn ecdh(secret_key: [secret_length]u8, public_key: [public_length]u8) mbed_p256.Error![shared_length]u8 {
        return mbed_p256.ecdh(secret_key, public_key);
    }
};

/// P-384 (secp384r1) key exchange using mbedTLS via C helper
/// See: lib/esp/src/idf/mbed_tls/p384_helper.c
pub const P384 = struct {
    pub const secret_length = 48;
    pub const public_length = 97; // Uncompressed SEC1: 04 || x || y
    pub const shared_length = 48;
    pub const seed_length = 48;
    pub const scalar_length = 48;

    pub const KeyPair = struct {
        secret_key: [secret_length]u8,
        public_key: [public_length]u8,

        pub fn generateDeterministic(seed: [seed_length]u8) mbed_p384.Error!KeyPair {
            const kp = try mbed_p384.KeyPair.generateDeterministic(seed);
            return KeyPair{
                .secret_key = kp.secret_key,
                .public_key = kp.public_key,
            };
        }
    };

    pub fn ecdh(secret_key: [secret_length]u8, public_key: [public_length]u8) mbed_p384.Error![shared_length]u8 {
        return mbed_p384.ecdh(secret_key, public_key);
    }
};

// ============================================================================
// KDF - HKDF
// ============================================================================

/// HKDF-SHA256 using C helper
pub const HkdfSha256 = struct {
    pub const prk_length = 32;

    /// Extract: salt is optional (null = zero-filled)
    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return mbed_hkdf.Sha256.extract(salt, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8 {
        return mbed_hkdf.Sha256.expand(prk, info, len);
    }
};

/// HKDF-SHA384 using C helper
pub const HkdfSha384 = struct {
    pub const prk_length = 48;

    /// Extract: salt is optional (null = zero-filled)
    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return mbed_hkdf.Sha384.extract(salt, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8 {
        return mbed_hkdf.Sha384.expand(prk, info, len);
    }
};

/// HKDF-SHA512 using C helper
pub const HkdfSha512 = struct {
    pub const prk_length = 64;

    /// Extract: salt is optional (null = zero-filled)
    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return mbed_hkdf.Sha512.extract(salt, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8 {
        return mbed_hkdf.Sha512.expand(prk, info, len);
    }
};

// ============================================================================
// MAC - HMAC
// ============================================================================

/// HMAC-SHA256 using mbedTLS
pub const HmacSha256 = struct {
    pub const mac_length = 32;
    pub const block_length = 64;

    ctx: mbed.md_context_t,

    pub fn init(key: []const u8) HmacSha256 {
        var self: HmacSha256 = undefined;
        mbed.md_init(&self.ctx);
        _ = mbed.md_setup(&self.ctx, mbed.md_info_from_type(mbed.MD_SHA256), 1);
        _ = mbed.md_hmac_starts(&self.ctx, key.ptr, key.len);
        return self;
    }

    pub fn update(self: *HmacSha256, data: []const u8) void {
        _ = mbed.md_hmac_update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *HmacSha256) [mac_length]u8 {
        var out: [mac_length]u8 = undefined;
        _ = mbed.md_hmac_finish(&self.ctx, &out);
        mbed.md_free(&self.ctx);
        return out;
    }

    /// One-shot HMAC
    pub fn create(out: *[mac_length]u8, data: []const u8, key: []const u8) void {
        _ = mbed.md_hmac(
            mbed.md_info_from_type(mbed.MD_SHA256),
            key.ptr,
            key.len,
            data.ptr,
            data.len,
            out,
        );
    }
};

/// HMAC-SHA384 using mbedTLS
pub const HmacSha384 = struct {
    pub const mac_length = 48;
    pub const block_length = 128;

    ctx: mbed.md_context_t,

    pub fn init(key: []const u8) HmacSha384 {
        var self: HmacSha384 = undefined;
        mbed.md_init(&self.ctx);
        _ = mbed.md_setup(&self.ctx, mbed.md_info_from_type(mbed.MD_SHA384), 1);
        _ = mbed.md_hmac_starts(&self.ctx, key.ptr, key.len);
        return self;
    }

    pub fn update(self: *HmacSha384, data: []const u8) void {
        _ = mbed.md_hmac_update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *HmacSha384) [mac_length]u8 {
        var out: [mac_length]u8 = undefined;
        _ = mbed.md_hmac_finish(&self.ctx, &out);
        mbed.md_free(&self.ctx);
        return out;
    }

    pub fn create(out: *[mac_length]u8, data: []const u8, key: []const u8) void {
        _ = mbed.md_hmac(
            mbed.md_info_from_type(mbed.MD_SHA384),
            key.ptr,
            key.len,
            data.ptr,
            data.len,
            out,
        );
    }
};

/// HMAC-SHA512 using mbedTLS
pub const HmacSha512 = struct {
    pub const mac_length = 64;
    pub const block_length = 128;

    ctx: mbed.md_context_t,

    pub fn init(key: []const u8) HmacSha512 {
        var self: HmacSha512 = undefined;
        mbed.md_init(&self.ctx);
        _ = mbed.md_setup(&self.ctx, mbed.md_info_from_type(mbed.MD_SHA512), 1);
        _ = mbed.md_hmac_starts(&self.ctx, key.ptr, key.len);
        return self;
    }

    pub fn update(self: *HmacSha512, data: []const u8) void {
        _ = mbed.md_hmac_update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *HmacSha512) [mac_length]u8 {
        var out: [mac_length]u8 = undefined;
        _ = mbed.md_hmac_finish(&self.ctx, &out);
        mbed.md_free(&self.ctx);
        return out;
    }

    pub fn create(out: *[mac_length]u8, data: []const u8, key: []const u8) void {
        _ = mbed.md_hmac(
            mbed.md_info_from_type(mbed.MD_SHA512),
            key.ptr,
            key.len,
            data.ptr,
            data.len,
            out,
        );
    }
};

// ============================================================================
// Digital Signatures (stubs - implement as needed)
// ============================================================================

pub const EcdsaP256Sha256 = struct {
    pub const Signature = struct {
        toBytes: fn () [64]u8,
    };
    pub const PublicKey = struct {};
};

pub const EcdsaP384Sha384 = struct {
    pub const Signature = struct {};
    pub const PublicKey = struct {};
};

pub const Ed25519 = struct {
    pub const Signature = struct {};
    pub const PublicKey = struct {};
};

// ============================================================================
// RSA (verify only - stub)
// ============================================================================

pub const rsa = struct {
    pub const PublicKey = struct {};
    pub const PSSSignature = struct {};
    pub const PKCS1v1_5Signature = struct {};
    pub const Hash = struct {};
};

// ============================================================================
// Random Number Generator (ESP32 Hardware RNG)
// ============================================================================

pub const Rng = struct {
    /// Fill buffer with random bytes from ESP32 hardware RNG
    pub fn fill(buf: []u8) void {
        idf.random.fill(buf);
    }
};

// ============================================================================
// X.509 Certificate Support
// ============================================================================

// NOTE: x509 is NOT exported because it depends on std.time which doesn't
// work on freestanding targets (ESP32). The TLS library will detect that
// x509 is not present and skip certificate verification.
//
// ============================================================================
// X.509 Certificate Support
// ============================================================================

/// X.509 certificate parsing and verification using mbedTLS
pub const x509 = @import("cert.zig");

// ============================================================================
// Suite type for convenience
// ============================================================================

pub const Suite = @This();
