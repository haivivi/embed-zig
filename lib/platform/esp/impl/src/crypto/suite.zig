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
const mbed_rsa = idf.mbed_tls.rsa_helper;

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
// Digital Signatures (mbedTLS implementation)
// ============================================================================

pub const EcdsaP256Sha256 = struct {
    pub const Signature = struct {
        r: [32]u8,
        s: [32]u8,

        pub fn fromDer(der: []const u8) !Signature {
            // Parse DER-encoded ECDSA signature
            // SEQUENCE { INTEGER r, INTEGER s }
            if (der.len < 6) return error.InvalidEncoding;
            if (der[0] != 0x30) return error.InvalidEncoding; // SEQUENCE

            var pos: usize = 2;
            if (der[1] & 0x80 != 0) pos = 3; // Long form length

            // Parse r
            if (der[pos] != 0x02) return error.InvalidEncoding; // INTEGER
            const r_len = der[pos + 1];
            pos += 2;
            const r_start = if (der[pos] == 0x00) pos + 1 else pos;
            const r_data = der[r_start..][0..@min(32, der.len - r_start)];
            pos += r_len;

            // Parse s
            if (pos >= der.len or der[pos] != 0x02) return error.InvalidEncoding;
            _ = der[pos + 1]; // s_len - not needed since we parse to end
            pos += 2;
            const s_start = if (der[pos] == 0x00) pos + 1 else pos;
            const s_data = der[s_start..][0..@min(32, der.len - s_start)];

            var sig = Signature{ .r = [_]u8{0} ** 32, .s = [_]u8{0} ** 32 };
            // Right-align the values
            const r_offset = 32 -| r_data.len;
            const s_offset = 32 -| s_data.len;
            @memcpy(sig.r[r_offset..][0..r_data.len], r_data);
            @memcpy(sig.s[s_offset..][0..s_data.len], s_data);
            return sig;
        }

        pub fn verify(self: Signature, msg: []const u8, pk: PublicKey) !void {
            // Hash the message first
            var hash: [32]u8 = undefined;
            Sha256.hash(msg, &hash, .{});

            // Use mbedTLS ECDSA verify
            var grp: mbed.mbedtls_ecp_group = undefined;
            mbed.mbedtls_ecp_group_init(&grp);
            defer mbed.mbedtls_ecp_group_free(&grp);

            if (mbed.mbedtls_ecp_group_load(&grp, mbed.MBEDTLS_ECP_DP_SECP256R1) != 0) {
                return error.SignatureVerificationFailed;
            }

            // Load public key point
            var Q: mbed.mbedtls_ecp_point = undefined;
            mbed.mbedtls_ecp_point_init(&Q);
            defer mbed.mbedtls_ecp_point_free(&Q);

            if (mbed.mbedtls_ecp_point_read_binary(&grp, &Q, &pk.bytes, pk.bytes.len) != 0) {
                return error.InvalidPublicKey;
            }

            // Load r and s as MPIs
            var r_mpi: mbed.mbedtls_mpi = undefined;
            var s_mpi: mbed.mbedtls_mpi = undefined;
            mbed.mbedtls_mpi_init(&r_mpi);
            mbed.mbedtls_mpi_init(&s_mpi);
            defer mbed.mbedtls_mpi_free(&r_mpi);
            defer mbed.mbedtls_mpi_free(&s_mpi);

            if (mbed.mbedtls_mpi_read_binary(&r_mpi, &self.r, 32) != 0) {
                return error.InvalidSignature;
            }
            if (mbed.mbedtls_mpi_read_binary(&s_mpi, &self.s, 32) != 0) {
                return error.InvalidSignature;
            }

            // Verify
            if (mbed.mbedtls_ecdsa_verify(&grp, &hash, hash.len, &Q, &r_mpi, &s_mpi) != 0) {
                return error.SignatureVerificationFailed;
            }
        }
    };

    pub const PublicKey = struct {
        bytes: [65]u8, // Uncompressed point: 0x04 || x || y

        pub fn fromSec1(sec1: []const u8) !PublicKey {
            if (sec1.len != 65 or sec1[0] != 0x04) {
                return error.InvalidEncoding;
            }
            var pk = PublicKey{ .bytes = undefined };
            @memcpy(&pk.bytes, sec1[0..65]);
            return pk;
        }
    };

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

pub const EcdsaP384Sha384 = struct {
    pub const Signature = struct {
        r: [48]u8,
        s: [48]u8,

        pub fn fromDer(der: []const u8) !Signature {
            if (der.len < 6) return error.InvalidEncoding;
            if (der[0] != 0x30) return error.InvalidEncoding;

            var pos: usize = 2;
            if (der[1] & 0x80 != 0) pos = 3;

            if (der[pos] != 0x02) return error.InvalidEncoding;
            const r_len = der[pos + 1];
            pos += 2;
            const r_start = if (der[pos] == 0x00) pos + 1 else pos;
            const r_data = der[r_start..][0..@min(48, der.len - r_start)];
            pos += r_len;

            if (pos >= der.len or der[pos] != 0x02) return error.InvalidEncoding;
            _ = der[pos + 1]; // s_len - not needed
            pos += 2;
            const s_start = if (der[pos] == 0x00) pos + 1 else pos;
            const s_data = der[s_start..][0..@min(48, der.len - s_start)];

            var sig = Signature{ .r = [_]u8{0} ** 48, .s = [_]u8{0} ** 48 };
            const r_offset = 48 -| r_data.len;
            const s_offset = 48 -| s_data.len;
            @memcpy(sig.r[r_offset..][0..r_data.len], r_data);
            @memcpy(sig.s[s_offset..][0..s_data.len], s_data);
            return sig;
        }

        pub fn verify(self: Signature, msg: []const u8, pk: PublicKey) !void {
            var hash: [48]u8 = undefined;
            Sha384.hash(msg, &hash, .{});

            var grp: mbed.mbedtls_ecp_group = undefined;
            mbed.mbedtls_ecp_group_init(&grp);
            defer mbed.mbedtls_ecp_group_free(&grp);

            if (mbed.mbedtls_ecp_group_load(&grp, mbed.MBEDTLS_ECP_DP_SECP384R1) != 0) {
                return error.SignatureVerificationFailed;
            }

            var Q: mbed.mbedtls_ecp_point = undefined;
            mbed.mbedtls_ecp_point_init(&Q);
            defer mbed.mbedtls_ecp_point_free(&Q);

            if (mbed.mbedtls_ecp_point_read_binary(&grp, &Q, &pk.bytes, pk.bytes.len) != 0) {
                return error.InvalidPublicKey;
            }

            var r_mpi: mbed.mbedtls_mpi = undefined;
            var s_mpi: mbed.mbedtls_mpi = undefined;
            mbed.mbedtls_mpi_init(&r_mpi);
            mbed.mbedtls_mpi_init(&s_mpi);
            defer mbed.mbedtls_mpi_free(&r_mpi);
            defer mbed.mbedtls_mpi_free(&s_mpi);

            if (mbed.mbedtls_mpi_read_binary(&r_mpi, &self.r, 48) != 0) {
                return error.InvalidSignature;
            }
            if (mbed.mbedtls_mpi_read_binary(&s_mpi, &self.s, 48) != 0) {
                return error.InvalidSignature;
            }

            if (mbed.mbedtls_ecdsa_verify(&grp, &hash, hash.len, &Q, &r_mpi, &s_mpi) != 0) {
                return error.SignatureVerificationFailed;
            }
        }
    };

    pub const PublicKey = struct {
        bytes: [97]u8, // Uncompressed: 0x04 || x || y

        pub fn fromSec1(sec1: []const u8) !PublicKey {
            if (sec1.len != 97 or sec1[0] != 0x04) {
                return error.InvalidEncoding;
            }
            var pk = PublicKey{ .bytes = undefined };
            @memcpy(&pk.bytes, sec1[0..97]);
            return pk;
        }
    };

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

pub const Ed25519 = struct {
    pub const Signature = struct {};
    pub const PublicKey = struct {};
};

// ============================================================================
// RSA Signatures (mbedTLS implementation)
// ============================================================================

pub const rsa = struct {
    pub const PublicKey = struct {
        n: []const u8, // modulus
        e: []const u8, // exponent

        pub fn parseDer(der: []const u8) !struct { modulus: []const u8, exponent: []const u8 } {
            // Parse RSA public key from DER: SEQUENCE { INTEGER n, INTEGER e }
            if (der.len < 4) return error.CertificatePublicKeyInvalid;
            if (der[0] != 0x30) return error.CertificatePublicKeyInvalid;

            var pos: usize = 2;
            if (der[1] & 0x80 != 0) {
                const len_bytes = der[1] & 0x7f;
                pos = 2 + len_bytes;
            }

            // Parse n (modulus)
            if (pos >= der.len or der[pos] != 0x02) return error.CertificatePublicKeyInvalid;
            pos += 1;
            var n_len: usize = der[pos];
            pos += 1;
            if (n_len & 0x80 != 0) {
                const len_bytes = n_len & 0x7f;
                n_len = 0;
                for (der[pos..][0..len_bytes]) |b| {
                    n_len = (n_len << 8) | b;
                }
                pos += len_bytes;
            }
            // Skip leading zeros
            while (n_len > 0 and der[pos] == 0) {
                pos += 1;
                n_len -= 1;
            }
            const modulus = der[pos..][0..n_len];
            pos += n_len;

            // Parse e (exponent)
            if (pos >= der.len or der[pos] != 0x02) return error.CertificatePublicKeyInvalid;
            pos += 1;
            var e_len: usize = der[pos];
            pos += 1;
            if (e_len & 0x80 != 0) {
                const len_bytes = e_len & 0x7f;
                e_len = 0;
                for (der[pos..][0..len_bytes]) |b| {
                    e_len = (e_len << 8) | b;
                }
                pos += len_bytes;
            }
            const exponent = der[pos..][0..e_len];

            return .{ .modulus = modulus, .exponent = exponent };
        }

        pub fn fromBytes(exponent: []const u8, modulus: []const u8) !PublicKey {
            return PublicKey{ .n = modulus, .e = exponent };
        }
    };

    pub const PKCS1v1_5Signature = struct {
        pub fn verify(
            comptime modulus_len: usize,
            sig: [modulus_len]u8,
            msg: []const u8,
            pk: PublicKey,
            comptime hash_type: HashType,
        ) !void {
            // Hash the message
            const hash_id: mbed_rsa.HashId = switch (hash_type) {
                .sha256 => .sha256,
                .sha384 => .sha384,
                .sha512 => .sha512,
            };

            var hash_buf: [64]u8 = undefined;
            const hash = switch (hash_type) {
                .sha256 => blk: {
                    Sha256.hash(msg, hash_buf[0..32], .{});
                    break :blk hash_buf[0..32];
                },
                .sha384 => blk: {
                    Sha384.hash(msg, hash_buf[0..48], .{});
                    break :blk hash_buf[0..48];
                },
                .sha512 => blk: {
                    Sha512.hash(msg, &hash_buf, .{});
                    break :blk hash_buf[0..64];
                },
            };

            // Verify signature using mbedTLS helper
            mbed_rsa.pkcs1v15Verify(pk.n, pk.e, hash, &sig, hash_id) catch
                return error.SignatureVerificationFailed;
        }
    };

    pub const PSSSignature = struct {
        pub fn verify(
            comptime modulus_len: usize,
            sig: [modulus_len]u8,
            msg: []const u8,
            pk: PublicKey,
            comptime hash_type: HashType,
        ) !void {
            // Hash the message
            const hash_id: mbed_rsa.HashId = switch (hash_type) {
                .sha256 => .sha256,
                .sha384 => .sha384,
                .sha512 => .sha512,
            };

            var hash_buf: [64]u8 = undefined;
            const hash = switch (hash_type) {
                .sha256 => blk: {
                    Sha256.hash(msg, hash_buf[0..32], .{});
                    break :blk hash_buf[0..32];
                },
                .sha384 => blk: {
                    Sha384.hash(msg, hash_buf[0..48], .{});
                    break :blk hash_buf[0..48];
                },
                .sha512 => blk: {
                    Sha512.hash(msg, &hash_buf, .{});
                    break :blk hash_buf[0..64];
                },
            };

            // Verify signature using mbedTLS helper
            mbed_rsa.pssVerify(pk.n, pk.e, hash, &sig, hash_id) catch
                return error.SignatureVerificationFailed;
        }
    };

    pub const HashType = enum { sha256, sha384, sha512 };
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
