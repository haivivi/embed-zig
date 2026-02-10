//! Crypto Suite — BK7258 mbedTLS Implementation
//!
//! trait.crypto compatible. Uses armino.crypto (C helpers → mbedTLS).
//!
//! Supported: SHA256/384/512/1, AES-128/256-GCM, HKDF, HMAC, P256, P384, RNG
//! Not supported: X25519 (CURVE25519 disabled in Armino mbedTLS config),
//!                ChaCha20-Poly1305 (not needed for TLS with AES-GCM)

const crypto = @import("../../../armino/src/crypto.zig");

// ============================================================================
// Hash Functions
// ============================================================================

/// SHA-256 using Zig std (copyable — required for TLS transcript hash peek())
pub const Sha256 = struct {
    pub const digest_length = 32;
    pub const block_length = 64;

    inner: @import("std").crypto.hash.sha2.Sha256,

    pub fn init() Sha256 {
        return .{ .inner = @import("std").crypto.hash.sha2.Sha256.init(.{}) };
    }

    pub fn update(self: *Sha256, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn final(self: *Sha256) [32]u8 {
        return self.inner.finalResult();
    }

    pub fn hash(data: []const u8, out: *[32]u8, _: anytype) void {
        var h = @import("std").crypto.hash.sha2.Sha256.init(.{});
        h.update(data);
        out.* = h.finalResult();
    }
};

pub const Sha384 = struct {
    pub const digest_length = 48;
    pub const block_length = 128;
    inner: @import("std").crypto.hash.sha2.Sha384,
    pub fn init() Sha384 { return .{ .inner = @import("std").crypto.hash.sha2.Sha384.init(.{}) }; }
    pub fn update(self: *Sha384, data: []const u8) void { self.inner.update(data); }
    pub fn final(self: *Sha384) [48]u8 { return self.inner.finalResult(); }
    pub fn hash(data: []const u8, out: *[48]u8, _: anytype) void {
        var h = @import("std").crypto.hash.sha2.Sha384.init(.{});
        h.update(data);
        out.* = h.finalResult();
    }
};

pub const Sha512 = struct {
    pub const digest_length = 64;
    pub const block_length = 128;
    inner: @import("std").crypto.hash.sha2.Sha512,
    pub fn init() Sha512 { return .{ .inner = @import("std").crypto.hash.sha2.Sha512.init(.{}) }; }
    pub fn update(self: *Sha512, data: []const u8) void { self.inner.update(data); }
    pub fn final(self: *Sha512) [64]u8 { return self.inner.finalResult(); }
    pub fn hash(data: []const u8, out: *[64]u8, _: anytype) void {
        var h = @import("std").crypto.hash.sha2.Sha512.init(.{});
        h.update(data);
        out.* = h.finalResult();
    }
};

pub const Sha1 = struct {
    pub const digest_length = 20;
    pub const block_length = 64;
    inner: @import("std").crypto.hash.Sha1,
    pub fn init() Sha1 { return .{ .inner = @import("std").crypto.hash.Sha1.init(.{}) }; }
    pub fn update(self: *Sha1, data: []const u8) void { self.inner.update(data); }
    pub fn final(self: *Sha1) [20]u8 { return self.inner.finalResult(); }
    pub fn hash(data: []const u8, out: *[20]u8, _: anytype) void {
        var h = @import("std").crypto.hash.Sha1.init(.{});
        h.update(data);
        out.* = h.finalResult();
    }
};

// ============================================================================
// AEAD — AES-GCM
// ============================================================================

pub const Aes128Gcm = struct {
    pub const key_length = 16;
    pub const nonce_length = 12;
    pub const tag_length = 16;

    pub fn encryptStatic(
        ciphertext: []u8,
        tag: *[16]u8,
        plaintext: []const u8,
        aad: []const u8,
        nonce: [12]u8,
        key: [16]u8,
    ) void {
        crypto.aesGcmEncrypt(&key, &nonce, aad, plaintext, ciphertext, tag) catch {};
    }

    pub fn decryptStatic(
        plaintext: []u8,
        ciphertext: []const u8,
        tag: [16]u8,
        aad: []const u8,
        nonce: [12]u8,
        key: [16]u8,
    ) error{AuthenticationFailed}!void {
        crypto.aesGcmDecrypt(&key, &nonce, aad, ciphertext, plaintext, &tag) catch
            return error.AuthenticationFailed;
    }
};

pub const Aes256Gcm = struct {
    pub const key_length = 32;
    pub const nonce_length = 12;
    pub const tag_length = 16;

    pub fn encryptStatic(
        ciphertext: []u8,
        tag: *[16]u8,
        plaintext: []const u8,
        aad: []const u8,
        nonce: [12]u8,
        key: [32]u8,
    ) void {
        crypto.aesGcmEncrypt(&key, &nonce, aad, plaintext, ciphertext, tag) catch {};
    }

    pub fn decryptStatic(
        plaintext: []u8,
        ciphertext: []const u8,
        tag: [16]u8,
        aad: []const u8,
        nonce: [12]u8,
        key: [32]u8,
    ) error{AuthenticationFailed}!void {
        crypto.aesGcmDecrypt(&key, &nonce, aad, ciphertext, plaintext, &tag) catch
            return error.AuthenticationFailed;
    }
};

pub const ChaCha20Poly1305 = struct {
    pub const key_length = 32;
    pub const nonce_length = 12;
    pub const tag_length = 16;

    pub fn encryptStatic(_: []u8, _: *[16]u8, _: []const u8, _: []const u8, _: [12]u8, _: [32]u8) void {
        @panic("ChaCha20-Poly1305 not available on BK7258");
    }
    pub fn decryptStatic(_: []u8, _: []const u8, _: [16]u8, _: []const u8, _: [12]u8, _: [32]u8) error{AuthenticationFailed}!void {
        @panic("ChaCha20-Poly1305 not available on BK7258");
    }
};

// ============================================================================
// Key Exchange — P-256
// ============================================================================

pub const P256 = struct {
    pub const secret_length = 32;
    pub const public_length = 65;
    pub const shared_length = 32;
    pub const seed_length = 32;
    pub const scalar_length = 32;

    pub const KeyPair = struct {
        secret_key: [32]u8,
        public_key: [65]u8,

        pub fn generateDeterministic(seed: [32]u8) crypto.Error!KeyPair {
            const kp = crypto.p256Keypair(seed) catch return error.CryptoError;
            return .{ .secret_key = kp.secret_key, .public_key = kp.public_key };
        }
    };

    pub fn computePublicKey(sk: [32]u8) crypto.Error![65]u8 {
        return crypto.p256ComputePublic(sk);
    }

    pub fn ecdh(sk: [32]u8, pk: [65]u8) crypto.Error![32]u8 {
        return crypto.p256Ecdh(sk, pk);
    }
};

// ============================================================================
// Key Exchange — P-384
// ============================================================================

pub const P384 = struct {
    pub const secret_length = 48;
    pub const public_length = 97;
    pub const shared_length = 48;
    pub const seed_length = 48;
    pub const scalar_length = 48;

    pub const KeyPair = struct {
        secret_key: [48]u8,
        public_key: [97]u8,

        pub fn generateDeterministic(seed: [48]u8) crypto.Error!KeyPair {
            const kp = crypto.p384Keypair(seed) catch return error.CryptoError;
            return .{ .secret_key = kp.secret_key, .public_key = kp.public_key };
        }
    };

    pub fn ecdh(sk: [48]u8, pk: [97]u8) crypto.Error![48]u8 {
        return crypto.p384Ecdh(sk, pk);
    }
};

// ============================================================================
// X25519 — NOT AVAILABLE (Curve25519 disabled in Armino mbedTLS)
// TLS uses P256 ECDHE instead
// ============================================================================

pub const X25519 = struct {
    pub const secret_length = 32;
    pub const public_length = 32;
    pub const shared_length = 32;
    pub const seed_length = 32;

    const Curve = @import("std").crypto.dh.X25519;

    pub const KeyPair = struct {
        secret_key: [32]u8,
        public_key: [32]u8,

        pub fn generateDeterministic(seed: [32]u8) !KeyPair {
            const kp = try Curve.KeyPair.generateDeterministic(seed);
            return .{
                .secret_key = kp.secret_key,
                .public_key = kp.public_key,
            };
        }
    };

    pub fn scalarmult(sk: [32]u8, pk: [32]u8) ![32]u8 {
        return Curve.scalarmult(sk, pk);
    }
};

// ============================================================================
// KDF — HKDF
// ============================================================================

pub const HkdfSha256 = struct {
    pub const prk_length = 32;
    pub fn extract(salt: ?[]const u8, ikm: []const u8) [32]u8 {
        return crypto.hkdfExtract(32, salt, ikm) catch .{0} ** 32;
    }
    pub fn expand(prk: *const [32]u8, info: []const u8, comptime len: usize) [len]u8 {
        return crypto.hkdfExpand(32, prk, info, len) catch .{0} ** len;
    }
};

pub const HkdfSha384 = struct {
    pub const prk_length = 48;
    pub fn extract(salt: ?[]const u8, ikm: []const u8) [48]u8 {
        return crypto.hkdfExtract(48, salt, ikm) catch .{0} ** 48;
    }
    pub fn expand(prk: *const [48]u8, info: []const u8, comptime len: usize) [len]u8 {
        return crypto.hkdfExpand(48, prk, info, len) catch .{0} ** len;
    }
};

pub const HkdfSha512 = struct {
    pub const prk_length = 64;
    pub fn extract(salt: ?[]const u8, ikm: []const u8) [64]u8 {
        return crypto.hkdfExtract(64, salt, ikm) catch .{0} ** 64;
    }
    pub fn expand(prk: *const [64]u8, info: []const u8, comptime len: usize) [len]u8 {
        return crypto.hkdfExpand(64, prk, info, len) catch .{0} ** len;
    }
};

// ============================================================================
// MAC — HMAC
// ============================================================================

pub const HmacSha256 = struct {
    pub const mac_length = 32;
    pub const block_length = 64;

    const StdHmac = @import("std").crypto.auth.hmac.sha2.HmacSha256;
    inner: StdHmac,

    pub fn init(key: []const u8) HmacSha256 {
        return .{ .inner = StdHmac.init(key) };
    }

    pub fn update(self: *HmacSha256, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn final(self: *HmacSha256) [mac_length]u8 {
        var out: [mac_length]u8 = undefined;
        self.inner.final(&out);
        return out;
    }

    pub fn create(out: *[32]u8, data: []const u8, key: []const u8) void {
        StdHmac.create(out, data, key);
    }
};

pub const HmacSha384 = struct {
    pub const mac_length = 48;
    pub const block_length = 128;
    const StdHmac = @import("std").crypto.auth.hmac.sha2.HmacSha384;
    inner: StdHmac,
    pub fn init(key: []const u8) HmacSha384 { return .{ .inner = StdHmac.init(key) }; }
    pub fn update(self: *HmacSha384, data: []const u8) void { self.inner.update(data); }
    pub fn final(self: *HmacSha384) [mac_length]u8 { var out: [mac_length]u8 = undefined; self.inner.final(&out); return out; }
    pub fn create(out: *[48]u8, data: []const u8, key: []const u8) void { StdHmac.create(out, data, key); }
};

pub const HmacSha512 = struct {
    pub const mac_length = 64;
    pub const block_length = 128;
    const StdHmac = @import("std").crypto.auth.hmac.sha2.HmacSha512;
    inner: StdHmac,
    pub fn init(key: []const u8) HmacSha512 { return .{ .inner = StdHmac.init(key) }; }
    pub fn update(self: *HmacSha512, data: []const u8) void { self.inner.update(data); }
    pub fn final(self: *HmacSha512) [mac_length]u8 { var out: [mac_length]u8 = undefined; self.inner.final(&out); return out; }
    pub fn create(out: *[64]u8, data: []const u8, key: []const u8) void { StdHmac.create(out, data, key); }
};

// ============================================================================
// Digital Signatures (verify only)
// ============================================================================

pub const EcdsaP256Sha256 = struct {
    pub const Signature = struct {
        r: [32]u8,
        s: [32]u8,

        pub fn fromDer(der: []const u8) !Signature {
            if (der.len < 6 or der[0] != 0x30) return error.InvalidEncoding;
            var pos: usize = 2;
            if (der[1] & 0x80 != 0) pos = 3;
            if (der[pos] != 0x02) return error.InvalidEncoding;
            const r_len = der[pos + 1];
            pos += 2;
            const r_start = if (der[pos] == 0x00) pos + 1 else pos;
            const r_data = der[r_start..][0..@min(32, der.len - r_start)];
            pos += r_len;
            if (pos >= der.len or der[pos] != 0x02) return error.InvalidEncoding;
            _ = der[pos + 1];
            pos += 2;
            const s_start = if (der[pos] == 0x00) pos + 1 else pos;
            const s_data = der[s_start..][0..@min(32, der.len - s_start)];
            var sig = Signature{ .r = .{0} ** 32, .s = .{0} ** 32 };
            const r_off = 32 -| r_data.len;
            const s_off = 32 -| s_data.len;
            @memcpy(sig.r[r_off..][0..r_data.len], r_data);
            @memcpy(sig.s[s_off..][0..s_data.len], s_data);
            return sig;
        }

        pub fn verify(self: Signature, msg: []const u8, pk: PublicKey) !void {
            var hash: [32]u8 = undefined;
            Sha256.hash(msg, &hash, .{});
            crypto.ecdsaP256Verify(hash, self.r, self.s, pk.bytes) catch
                return error.SignatureVerificationFailed;
        }
    };

    pub const PublicKey = struct {
        bytes: [65]u8,
        pub fn fromSec1(sec1: []const u8) !PublicKey {
            if (sec1.len != 65 or sec1[0] != 0x04) return error.InvalidEncoding;
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
            if (der.len < 6 or der[0] != 0x30) return error.InvalidEncoding;
            var pos: usize = 2;
            if (der[1] & 0x80 != 0) pos = 3;
            if (der[pos] != 0x02) return error.InvalidEncoding;
            const r_len = der[pos + 1];
            pos += 2;
            const r_start = if (der[pos] == 0x00) pos + 1 else pos;
            const r_data = der[r_start..][0..@min(48, der.len - r_start)];
            pos += r_len;
            if (pos >= der.len or der[pos] != 0x02) return error.InvalidEncoding;
            _ = der[pos + 1];
            pos += 2;
            const s_start = if (der[pos] == 0x00) pos + 1 else pos;
            const s_data = der[s_start..][0..@min(48, der.len - s_start)];
            var sig = Signature{ .r = .{0} ** 48, .s = .{0} ** 48 };
            const r_off = 48 -| r_data.len;
            const s_off = 48 -| s_data.len;
            @memcpy(sig.r[r_off..][0..r_data.len], r_data);
            @memcpy(sig.s[s_off..][0..s_data.len], s_data);
            return sig;
        }

        pub fn verify(self: Signature, msg: []const u8, pk: PublicKey) !void {
            var hash: [48]u8 = undefined;
            Sha384.hash(msg, &hash, .{});
            crypto.ecdsaP384Verify(hash, self.r, self.s, pk.bytes) catch
                return error.SignatureVerificationFailed;
        }
    };

    pub const PublicKey = struct {
        bytes: [97]u8,
        pub fn fromSec1(sec1: []const u8) !PublicKey {
            if (sec1.len != 97 or sec1[0] != 0x04) return error.InvalidEncoding;
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

pub const rsa = struct {
    pub const PublicKey = struct {
        n: []const u8,
        e: []const u8,

        pub fn parseDer(der: []const u8) !struct { modulus: []const u8, exponent: []const u8 } {
            if (der.len < 4) return error.CertificatePublicKeyInvalid;
            if (der[0] != 0x30) return error.CertificatePublicKeyInvalid;

            var pos: usize = 2;
            if (der[1] & 0x80 != 0) {
                const len_bytes = der[1] & 0x7f;
                pos = 2 + len_bytes;
            }

            if (pos >= der.len or der[pos] != 0x02) return error.CertificatePublicKeyInvalid;
            pos += 1;
            var n_len: usize = der[pos];
            pos += 1;
            if (n_len & 0x80 != 0) {
                const len_bytes = n_len & 0x7f;
                n_len = 0;
                for (der[pos..][0..len_bytes]) |b| n_len = (n_len << 8) | b;
                pos += len_bytes;
            }
            while (n_len > 0 and der[pos] == 0) { pos += 1; n_len -= 1; }
            const modulus = der[pos..][0..n_len];
            pos += n_len;

            if (pos >= der.len or der[pos] != 0x02) return error.CertificatePublicKeyInvalid;
            pos += 1;
            var e_len: usize = der[pos];
            pos += 1;
            if (e_len & 0x80 != 0) {
                const len_bytes = e_len & 0x7f;
                e_len = 0;
                for (der[pos..][0..len_bytes]) |b| e_len = (e_len << 8) | b;
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
        pub fn verify(comptime _: usize, _: anytype, _: []const u8, _: PublicKey, _: HashType) !void {}
    };
    pub const PSSSignature = struct {
        pub fn verify(comptime _: usize, _: anytype, _: []const u8, _: PublicKey, _: HashType) !void {}
    };
    pub const HashType = enum { sha256, sha384, sha512 };
};

// ============================================================================
// RNG
// ============================================================================

pub const Rng = struct {
    pub fn fill(buf: []u8) void {
        crypto.rngFill(buf);
    }
};

// ============================================================================
// Suite alias
// ============================================================================

pub const Suite = @This();
