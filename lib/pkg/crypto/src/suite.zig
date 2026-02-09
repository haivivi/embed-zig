//! Crypto Suite - std.crypto Wrapper
//!
//! Wraps std.crypto primitives to conform to trait.crypto interface.
//! Provides a portable crypto implementation for non-ESP platforms.
//!
//! Usage:
//! ```zig
//! const Crypto = @import("crypto").Suite;
//! const TlsClient = tls.Client(Socket, Crypto);
//! ```
//!
//! For ESP32 with hardware acceleration, use lib/esp/impl/src/crypto/suite.zig instead.

const std = @import("std");

// ============================================================================
// Hash Functions - Wrapper for init() compatibility
// ============================================================================

fn HashWrapper(comptime StdHash: type) type {
    return struct {
        pub const digest_length = StdHash.digest_length;
        pub const block_length = StdHash.block_length;

        inner: StdHash,

        pub fn init() @This() {
            return .{ .inner = StdHash.init(.{}) };
        }

        pub fn update(self: *@This(), data: []const u8) void {
            self.inner.update(data);
        }

        pub fn final(self: *@This()) [digest_length]u8 {
            var out: [digest_length]u8 = undefined;
            self.inner.final(&out);
            return out;
        }

        pub fn hash(data: []const u8, out: *[digest_length]u8, opts: anytype) void {
            _ = opts;
            StdHash.hash(data, out, .{});
        }
    };
}

pub const Sha256 = HashWrapper(std.crypto.hash.sha2.Sha256);
pub const Sha384 = HashWrapper(std.crypto.hash.sha2.Sha384);
pub const Sha512 = HashWrapper(std.crypto.hash.sha2.Sha512);
pub const Sha1 = HashWrapper(std.crypto.hash.Sha1);
pub const Blake2s256 = HashWrapper(std.crypto.hash.blake2.Blake2s256);
pub const Blake2b512 = HashWrapper(std.crypto.hash.blake2.Blake2b512);

// ============================================================================
// AEAD - Wrapper for encryptStatic/decryptStatic interface
// ============================================================================

fn AeadWrapper(comptime StdAead: type) type {
    return struct {
        pub const key_length = StdAead.key_length;
        pub const nonce_length = StdAead.nonce_length;
        pub const tag_length = StdAead.tag_length;

        pub fn encryptStatic(
            ciphertext: []u8,
            tag: *[tag_length]u8,
            plaintext: []const u8,
            aad: []const u8,
            nonce: [nonce_length]u8,
            key: [key_length]u8,
        ) void {
            StdAead.encrypt(ciphertext[0..plaintext.len], tag, plaintext, aad, nonce, key);
        }

        pub fn decryptStatic(
            plaintext: []u8,
            ciphertext: []const u8,
            tag: [tag_length]u8,
            aad: []const u8,
            nonce: [nonce_length]u8,
            key: [key_length]u8,
        ) error{AuthenticationFailed}!void {
            StdAead.decrypt(plaintext[0..ciphertext.len], ciphertext, tag, aad, nonce, key) catch {
                return error.AuthenticationFailed;
            };
        }
    };
}

pub const Aes128Gcm = AeadWrapper(std.crypto.aead.aes_gcm.Aes128Gcm);
pub const Aes256Gcm = AeadWrapper(std.crypto.aead.aes_gcm.Aes256Gcm);
pub const ChaCha20Poly1305 = AeadWrapper(std.crypto.aead.chacha_poly.ChaCha20Poly1305);

// ============================================================================
// Key Exchange - X25519 Wrapper
// ============================================================================

pub const X25519 = struct {
    pub const secret_length = 32;
    pub const public_length = 32;
    pub const shared_length = 32;

    pub const KeyPair = struct {
        secret_key: [32]u8,
        public_key: [32]u8,

        pub fn generateDeterministic(seed: [32]u8) !KeyPair {
            const kp = std.crypto.dh.X25519.KeyPair.generateDeterministic(seed) catch {
                return error.IdentityElement;
            };
            return KeyPair{
                .secret_key = kp.secret_key,
                .public_key = kp.public_key,
            };
        }
    };

    pub fn scalarmult(secret_key: [32]u8, public_key: [32]u8) ![32]u8 {
        return std.crypto.dh.X25519.scalarmult(secret_key, public_key) catch {
            return error.WeakPublicKey;
        };
    }
};

// ============================================================================
// Key Exchange - P-256 Wrapper
// ============================================================================

pub const P256 = struct {
    pub const scalar_length = 32;
    const Curve = std.crypto.ecc.P256;
    const Scalar = std.crypto.ecc.P256.scalar.Scalar;

    pub const KeyPair = struct {
        secret_key: [32]u8,
        public_key: [65]u8, // Uncompressed point

        pub fn generateDeterministic(seed: [32]u8) !KeyPair {
            return KeyPair{
                .secret_key = seed,
                .public_key = try computePublicKey(seed),
            };
        }
    };

    pub fn computePublicKey(secret_key: [32]u8) ![65]u8 {
        const sk = Scalar.fromBytes(secret_key, .big) catch {
            return error.InvalidSecretKey;
        };
        const pk = Curve.basePoint.mul(sk.toBytes(.big), .big) catch {
            return error.InvalidOperation;
        };
        return pk.toUncompressedSec1();
    }

    pub fn ecdh(secret_key: [32]u8, peer_public_key: [65]u8) ![32]u8 {
        // Parse peer public key (uncompressed format: 04 || x || y)
        if (peer_public_key[0] != 0x04) return error.InvalidPublicKey;

        const sk = Scalar.fromBytes(secret_key, .big) catch {
            return error.InvalidSecretKey;
        };
        const pk = Curve.fromSec1(&peer_public_key) catch {
            return error.InvalidPublicKey;
        };
        const shared = pk.mul(sk.toBytes(.big), .big) catch {
            return error.InvalidOperation;
        };
        return shared.affineCoordinates().x.toBytes(.big);
    }
};

// ============================================================================
// Key Exchange - P-384 Wrapper
// ============================================================================

pub const P384 = struct {
    pub const scalar_length = 48;
    const Curve = std.crypto.ecc.P384;
    const Scalar = std.crypto.ecc.P384.scalar.Scalar;

    pub const KeyPair = struct {
        secret_key: [48]u8,
        public_key: [97]u8, // Uncompressed point

        pub fn generateDeterministic(seed: [48]u8) !KeyPair {
            return KeyPair{
                .secret_key = seed,
                .public_key = try computePublicKey(seed),
            };
        }
    };

    pub fn computePublicKey(secret_key: [48]u8) ![97]u8 {
        const sk = Scalar.fromBytes(secret_key, .big) catch {
            return error.InvalidSecretKey;
        };
        const pk = Curve.basePoint.mul(sk.toBytes(.big), .big) catch {
            return error.InvalidOperation;
        };
        return pk.toUncompressedSec1();
    }

    pub fn ecdh(secret_key: [48]u8, peer_public_key: [97]u8) ![48]u8 {
        if (peer_public_key[0] != 0x04) return error.InvalidPublicKey;

        const sk = Scalar.fromBytes(secret_key, .big) catch {
            return error.InvalidSecretKey;
        };
        const pk = Curve.fromSec1(&peer_public_key) catch {
            return error.InvalidPublicKey;
        };
        const shared = pk.mul(sk.toBytes(.big), .big) catch {
            return error.InvalidOperation;
        };
        return shared.affineCoordinates().x.toBytes(.big);
    }
};

// ============================================================================
// KDF - HKDF (use std library directly with HMAC types)
// ============================================================================

pub const HkdfSha256 = struct {
    pub const prk_length = 32;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return std.crypto.kdf.hkdf.HkdfSha256.extract(salt orelse &[_]u8{}, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, ctx: []const u8, comptime len: usize) [len]u8 {
        var out: [len]u8 = undefined;
        std.crypto.kdf.hkdf.HkdfSha256.expand(&out, ctx, prk.*);
        return out;
    }
};

pub const HkdfSha384 = struct {
    pub const prk_length = 48;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return std.crypto.kdf.hkdf.HkdfSha384.extract(salt orelse &[_]u8{}, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, ctx: []const u8, comptime len: usize) [len]u8 {
        var out: [len]u8 = undefined;
        std.crypto.kdf.hkdf.HkdfSha384.expand(&out, ctx, prk.*);
        return out;
    }
};

pub const HkdfSha512 = struct {
    pub const prk_length = 64;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return std.crypto.kdf.hkdf.HkdfSha512.extract(salt orelse &[_]u8{}, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, ctx: []const u8, comptime len: usize) [len]u8 {
        var out: [len]u8 = undefined;
        std.crypto.kdf.hkdf.HkdfSha512.expand(&out, ctx, prk.*);
        return out;
    }
};

// ============================================================================
// MAC - HMAC Wrapper
// ============================================================================

fn HmacWrapper(comptime StdHmac: type) type {
    return struct {
        pub const mac_length = StdHmac.mac_length;
        pub const block_length = StdHmac.block_length;

        inner: StdHmac,

        pub fn create(out: *[mac_length]u8, msg: []const u8, key: []const u8) void {
            StdHmac.create(out, msg, key);
        }

        pub fn init(key: []const u8) @This() {
            return .{ .inner = StdHmac.init(key) };
        }

        pub fn update(self: *@This(), data: []const u8) void {
            self.inner.update(data);
        }

        pub fn final(self: *@This()) [mac_length]u8 {
            var out: [mac_length]u8 = undefined;
            self.inner.final(&out);
            return out;
        }
    };
}

pub const HmacSha256 = HmacWrapper(std.crypto.auth.hmac.sha2.HmacSha256);
pub const HmacSha384 = HmacWrapper(std.crypto.auth.hmac.sha2.HmacSha384);
pub const HmacSha512 = HmacWrapper(std.crypto.auth.hmac.sha2.HmacSha512);
pub const HmacBlake2s256 = HmacWrapper(std.crypto.auth.hmac.Hmac(std.crypto.hash.blake2.Blake2s256));

// ============================================================================
// Digital Signatures
// ============================================================================

pub const Ed25519 = struct {
    pub const Signature = std.crypto.sign.Ed25519.Signature;
    pub const PublicKey = std.crypto.sign.Ed25519.PublicKey;
    pub const SecretKey = std.crypto.sign.Ed25519.SecretKey;
    pub const KeyPair = std.crypto.sign.Ed25519.KeyPair;

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

pub const EcdsaP256Sha256 = struct {
    const EcdsaSig = std.crypto.sign.ecdsa.EcdsaP256Sha256.Signature;
    const EcdsaPk = std.crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey;

    pub const Signature = struct {
        inner: EcdsaSig,

        pub fn fromDer(der: []const u8) !Signature {
            const inner = EcdsaSig.fromDer(der) catch return error.InvalidEncoding;
            return Signature{ .inner = inner };
        }

        pub fn verify(self: Signature, msg: []const u8, pk: PublicKey) !void {
            self.inner.verify(msg, pk.inner) catch return error.SignatureVerificationFailed;
        }
    };

    pub const PublicKey = struct {
        inner: EcdsaPk,

        pub fn fromSec1(sec1: []const u8) !PublicKey {
            const inner = EcdsaPk.fromSec1(sec1) catch return error.InvalidEncoding;
            return PublicKey{ .inner = inner };
        }
    };

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

pub const EcdsaP384Sha384 = struct {
    const EcdsaSig = std.crypto.sign.ecdsa.EcdsaP384Sha384.Signature;
    const EcdsaPk = std.crypto.sign.ecdsa.EcdsaP384Sha384.PublicKey;

    pub const Signature = struct {
        inner: EcdsaSig,

        pub fn fromDer(der: []const u8) !Signature {
            const inner = EcdsaSig.fromDer(der) catch return error.InvalidEncoding;
            return Signature{ .inner = inner };
        }

        pub fn verify(self: Signature, msg: []const u8, pk: PublicKey) !void {
            self.inner.verify(msg, pk.inner) catch return error.SignatureVerificationFailed;
        }
    };

    pub const PublicKey = struct {
        inner: EcdsaPk,

        pub fn fromSec1(sec1: []const u8) !PublicKey {
            const inner = EcdsaPk.fromSec1(sec1) catch return error.InvalidEncoding;
            return PublicKey{ .inner = inner };
        }
    };

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

// ============================================================================
// RSA - Wrapper around std.crypto.Certificate.rsa
// ============================================================================

pub const rsa = struct {
    const StdRsa = std.crypto.Certificate.rsa;

    pub const PublicKey = struct {
        n: []const u8,
        e: []const u8,

        pub const ParseDerError = error{CertificatePublicKeyInvalid};

        pub fn parseDer(pub_key: []const u8) ParseDerError!struct { modulus: []const u8, exponent: []const u8 } {
            const result = StdRsa.PublicKey.parseDer(pub_key) catch return error.CertificatePublicKeyInvalid;
            return .{ .modulus = result.modulus, .exponent = result.exponent };
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
            const Hash = switch (hash_type) {
                .sha256 => std.crypto.hash.sha2.Sha256,
                .sha384 => std.crypto.hash.sha2.Sha384,
                .sha512 => std.crypto.hash.sha2.Sha512,
            };
            const std_pk = StdRsa.PublicKey.fromBytes(pk.e, pk.n) catch
                return error.CertificatePublicKeyInvalid;
            StdRsa.PKCS1v1_5Signature.verify(modulus_len, sig, msg, std_pk, Hash) catch
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
            const Hash = switch (hash_type) {
                .sha256 => std.crypto.hash.sha2.Sha256,
                .sha384 => std.crypto.hash.sha2.Sha384,
                .sha512 => std.crypto.hash.sha2.Sha512,
            };
            const std_pk = StdRsa.PublicKey.fromBytes(pk.e, pk.n) catch
                return error.CertificatePublicKeyInvalid;
            StdRsa.PSSSignature.verify(modulus_len, sig, msg, std_pk, Hash) catch
                return error.SignatureVerificationFailed;
        }
    };

    pub const HashType = enum { sha256, sha384, sha512 };
};

// ============================================================================
// Random Number Generator
// ============================================================================

pub const Rng = struct {
    pub fn fill(buf: []u8) void {
        std.crypto.random.bytes(buf);
    }
};

// ============================================================================
// X.509 Certificate Support - Keep existing wrapper
// ============================================================================

pub const x509 = @import("x509/x509.zig");

// ============================================================================
// Tests
// ============================================================================

test "Suite passes crypto trait validation" {
    const trait = @import("trait");

    // Validate crypto primitives exported by Suite
    const Validated = trait.crypto.from(@This(), .{
        // Hash functions
        .sha256 = true,
        .sha384 = true,
        .sha512 = true,
        .sha1 = true,
        .blake2s = true,
        .blake2b = true,
        // AEAD
        .aes_128_gcm = true,
        .aes_256_gcm = true,
        .chacha20_poly1305 = true,
        // Key Exchange
        .x25519 = true,
        .p256 = true,
        .p384 = true,
        // KDF
        .hkdf_sha256 = true,
        .hkdf_sha384 = true,
        .hkdf_sha512 = true,
        // MAC
        .hmac_sha256 = true,
        .hmac_sha384 = true,
        .hmac_sha512 = true,
        // X.509
        .x509 = true,
        // RNG
        .rng = true,
    });

    // Verify Hash types
    try std.testing.expect(Validated.Sha256.digest_length == 32);
    try std.testing.expect(Validated.Sha384.digest_length == 48);
    try std.testing.expect(Validated.Sha512.digest_length == 64);
    try std.testing.expect(Validated.Sha1.digest_length == 20);

    // Verify AEAD types
    try std.testing.expect(Validated.Aes128Gcm.key_length == 16);
    try std.testing.expect(Validated.Aes256Gcm.key_length == 32);
    try std.testing.expect(Validated.ChaCha20Poly1305.key_length == 32);

    // Verify Key Exchange types
    try std.testing.expect(Validated.X25519.secret_length == 32);

    // Verify KDF types
    try std.testing.expect(Validated.HkdfSha256.prk_length == 32);
    try std.testing.expect(Validated.HkdfSha384.prk_length == 48);
    try std.testing.expect(Validated.HkdfSha512.prk_length == 64);

    // Verify MAC types
    try std.testing.expect(Validated.HmacSha256.mac_length == 32);
    try std.testing.expect(Validated.HmacSha384.mac_length == 48);
    try std.testing.expect(Validated.HmacSha512.mac_length == 64);
}

test "AEAD encrypt/decrypt round trip" {
    const key: [16]u8 = [_]u8{0x01} ** 16;
    const nonce: [12]u8 = [_]u8{0x02} ** 12;
    const plaintext = "Hello, TLS!";
    const aad = "additional data";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    Aes128Gcm.encryptStatic(&ciphertext, &tag, plaintext, aad, nonce, key);

    var decrypted: [plaintext.len]u8 = undefined;
    try Aes128Gcm.decryptStatic(&decrypted, &ciphertext, tag, aad, nonce, key);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "X25519 key exchange" {
    var seed_a: [32]u8 = undefined;
    var seed_b: [32]u8 = undefined;
    Rng.fill(&seed_a);
    Rng.fill(&seed_b);

    const kp_a = try X25519.KeyPair.generateDeterministic(seed_a);
    const kp_b = try X25519.KeyPair.generateDeterministic(seed_b);

    const shared_a = try X25519.scalarmult(kp_a.secret_key, kp_b.public_key);
    const shared_b = try X25519.scalarmult(kp_b.secret_key, kp_a.public_key);

    try std.testing.expectEqualSlices(u8, &shared_a, &shared_b);
}

test "HKDF extract and expand" {
    const ikm = "input key material";
    const salt = "salt value";
    const info = "context info";

    const prk = HkdfSha256.extract(salt, ikm);
    const okm = HkdfSha256.expand(&prk, info, 32);

    try std.testing.expect(okm.len == 32);
}

test "HMAC create" {
    const key = "secret key";
    const msg = "message to authenticate";
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, msg, key);
    try std.testing.expect(mac.len == 32);
}
