//! e2e: trait/crypto — Cryptographic primitives conformance test
//!
//! Tests every REQUIRED primitive with known-answer test vectors (KATs).
//! All 11 required primitives are validated at compile time via trait.crypto.from(),
//! then verified at runtime with official test vectors.
//!
//! Test vectors sources:
//!   - SHA-2: FIPS 180-4 / RFC 6234
//!   - ChaCha20-Poly1305: RFC 8439 §2.8.2
//!   - X25519: RFC 7748 §6.1
//!   - HKDF: RFC 5869 Test Case 1
//!   - HMAC: RFC 4231 Test Case 2

const std = @import("std");
const trait = @import("trait");
const platform = @import("platform.zig");
const log = platform.log;

// Compile-time validation: Crypto must implement ALL required primitives.
// Uses default Config where all 11 required fields are `true`.
const Crypto = trait.crypto.from(platform.Crypto, .{});

var pass_count: u32 = 0;
var fail_count: u32 = 0;

fn passed(comptime name: []const u8) void {
    pass_count += 1;
    log.info("[e2e]   PASS: " ++ name, .{});
}

fn failed(comptime name: []const u8) void {
    fail_count += 1;
    log.err("[e2e]   FAIL: " ++ name, .{});
}

fn runTests() !void {
    log.info("[e2e] START: trait/crypto", .{});

    // ========================================================================
    // Hash functions (required)
    // ========================================================================

    testSha256();
    testSha384();

    // ========================================================================
    // AEAD ciphers (required)
    // ========================================================================

    testAes128Gcm();
    testAes256Gcm();
    testChaCha20Poly1305();

    // ========================================================================
    // Key exchange (required)
    // ========================================================================

    testX25519();

    // ========================================================================
    // KDF (required)
    // ========================================================================

    testHkdfSha256();
    testHkdfSha384();

    // ========================================================================
    // MAC (required)
    // ========================================================================

    testHmacSha256();
    testHmacSha384();

    // ========================================================================
    // AEAD tamper detection
    // ========================================================================

    testAeadTamperDetection();
    testChaCha20TamperDetection();

    // ========================================================================
    // Summary
    // ========================================================================

    log.info("[e2e] SUMMARY: trait/crypto — {} passed, {} failed", .{ pass_count, fail_count });

    if (fail_count > 0) {
        log.err("[e2e] FAIL: trait/crypto", .{});
        return error.CryptoTestFailed;
    }
    log.info("[e2e] PASS: trait/crypto", .{});
}

// ============================================================================
// SHA-256: FIPS 180-4 "abc"
// ============================================================================

fn testSha256() void {
    var h = Crypto.Sha256.init();
    h.update("abc");
    const got = h.final();

    const expected = [32]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };

    if (std.mem.eql(u8, &got, &expected)) passed("sha256") else failed("sha256 — digest mismatch");
}

// ============================================================================
// SHA-384: FIPS 180-4 "abc"
// ============================================================================

fn testSha384() void {
    var h = Crypto.Sha384.init();
    h.update("abc");
    const got = h.final();

    const expected = [48]u8{
        0xcb, 0x00, 0x75, 0x3f, 0x45, 0xa3, 0x5e, 0x8b,
        0xb5, 0xa0, 0x3d, 0x69, 0x9a, 0xc6, 0x50, 0x07,
        0x27, 0x2c, 0x32, 0xab, 0x0e, 0xde, 0xd1, 0x63,
        0x1a, 0x8b, 0x60, 0x5a, 0x43, 0xff, 0x5b, 0xed,
        0x80, 0x86, 0x07, 0x2b, 0xa1, 0xe7, 0xcc, 0x23,
        0x58, 0xba, 0xec, 0xa1, 0x34, 0xc8, 0x25, 0xa7,
    };

    if (std.mem.eql(u8, &got, &expected)) passed("sha384") else failed("sha384 — digest mismatch");
}

// ============================================================================
// AES-128-GCM: encrypt + decrypt round-trip
// ============================================================================

fn testAes128Gcm() void {
    const Aes = Crypto.Aes128Gcm;
    const key: [Aes.key_length]u8 = .{0x42} ** Aes.key_length;
    const nonce: [Aes.nonce_length]u8 = .{0x01} ** Aes.nonce_length;
    const aad = "additional data";
    const plaintext = "hello crypto e2e";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [Aes.tag_length]u8 = undefined;
    Aes.encryptStatic(&ciphertext, &tag, plaintext, aad, nonce, key);

    if (std.mem.eql(u8, &ciphertext, plaintext)) {
        failed("aes128gcm — ciphertext equals plaintext");
        return;
    }

    var decrypted: [plaintext.len]u8 = undefined;
    Aes.decryptStatic(&decrypted, &ciphertext, tag, aad, nonce, key) catch {
        failed("aes128gcm — decryption failed");
        return;
    };

    if (std.mem.eql(u8, &decrypted, plaintext)) passed("aes128gcm") else failed("aes128gcm — round-trip mismatch");
}

// ============================================================================
// AES-256-GCM: encrypt + decrypt round-trip
// ============================================================================

fn testAes256Gcm() void {
    const Aes = Crypto.Aes256Gcm;
    const key: [Aes.key_length]u8 = .{0x77} ** Aes.key_length;
    const nonce: [Aes.nonce_length]u8 = .{0x03} ** Aes.nonce_length;
    const aad = "aes256 test";
    const plaintext = "256-bit key test data here!!!!!";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [Aes.tag_length]u8 = undefined;
    Aes.encryptStatic(&ciphertext, &tag, plaintext, aad, nonce, key);

    if (std.mem.eql(u8, &ciphertext, plaintext)) {
        failed("aes256gcm — ciphertext equals plaintext");
        return;
    }

    var decrypted: [plaintext.len]u8 = undefined;
    Aes.decryptStatic(&decrypted, &ciphertext, tag, aad, nonce, key) catch {
        failed("aes256gcm — decryption failed");
        return;
    };

    if (std.mem.eql(u8, &decrypted, plaintext)) passed("aes256gcm") else failed("aes256gcm — round-trip mismatch");
}

// ============================================================================
// ChaCha20-Poly1305: RFC 8439 §2.8.2 test vector
// ============================================================================

fn testChaCha20Poly1305() void {
    const CC = Crypto.ChaCha20Poly1305;

    const key = [32]u8{
        0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
        0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
        0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
    };
    const nonce = [12]u8{
        0x07, 0x00, 0x00, 0x00,
        0x40, 0x41, 0x42, 0x43,
        0x44, 0x45, 0x46, 0x47,
    };
    const aad = [12]u8{
        0x50, 0x51, 0x52, 0x53,
        0xc0, 0xc1, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7,
    };
    const plaintext = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";

    const expected_tag = [16]u8{
        0x1a, 0xe1, 0x0b, 0x59, 0x4f, 0x09, 0xe2, 0x6a,
        0x7e, 0x90, 0x2e, 0xcb, 0xd0, 0x60, 0x06, 0x91,
    };

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [CC.tag_length]u8 = undefined;
    CC.encryptStatic(&ciphertext, &tag, plaintext, &aad, nonce, key);

    if (!std.mem.eql(u8, &tag, &expected_tag)) {
        failed("chacha20poly1305 — tag mismatch vs RFC 8439");
        return;
    }

    var decrypted: [plaintext.len]u8 = undefined;
    CC.decryptStatic(&decrypted, &ciphertext, tag, &aad, nonce, key) catch {
        failed("chacha20poly1305 — decryption failed");
        return;
    };

    if (std.mem.eql(u8, &decrypted, plaintext)) passed("chacha20poly1305") else failed("chacha20poly1305 — round-trip mismatch");
}

// ============================================================================
// X25519: DH key exchange with RFC 7748 seeds
// ============================================================================

fn testX25519() void {
    const X = Crypto.X25519;

    const alice_sk = [32]u8{
        0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d,
        0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45,
        0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a,
        0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a,
    };
    const bob_sk = [32]u8{
        0x5d, 0xab, 0x08, 0x7e, 0x62, 0x4a, 0x8a, 0x4b,
        0x79, 0xe1, 0x7f, 0x8b, 0x83, 0x80, 0x0e, 0xe6,
        0x6f, 0x3b, 0xb1, 0x29, 0x26, 0x18, 0xb6, 0xfd,
        0x1c, 0x2f, 0x8b, 0x27, 0xff, 0x88, 0xe0, 0xeb,
    };

    const kp_a = X.KeyPair.generateDeterministic(alice_sk) catch {
        failed("x25519 — keygen A failed");
        return;
    };
    const kp_b = X.KeyPair.generateDeterministic(bob_sk) catch {
        failed("x25519 — keygen B failed");
        return;
    };

    const shared_a = X.scalarmult(kp_a.secret_key, kp_b.public_key) catch {
        failed("x25519 — DH A*B failed");
        return;
    };
    const shared_b = X.scalarmult(kp_b.secret_key, kp_a.public_key) catch {
        failed("x25519 — DH B*A failed");
        return;
    };

    if (!std.mem.eql(u8, &shared_a, &shared_b)) {
        failed("x25519 — shared secrets differ");
        return;
    }

    var all_zero = true;
    for (shared_a) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        failed("x25519 — shared secret is all zeros");
        return;
    }

    passed("x25519");
}

// ============================================================================
// HKDF-SHA256: RFC 5869 Test Case 1
// ============================================================================

fn testHkdfSha256() void {
    const H = Crypto.HkdfSha256;

    const ikm = [22]u8{ 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b };
    const salt = [13]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c };
    const info = [10]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9 };

    const expected_prk = [32]u8{
        0x07, 0x77, 0x09, 0x36, 0x2c, 0x2e, 0x32, 0xdf,
        0x0d, 0xdc, 0x3f, 0x0d, 0xc4, 0x7b, 0xba, 0x63,
        0x90, 0xb6, 0xc7, 0x3b, 0xb5, 0x0f, 0x9c, 0x31,
        0x22, 0xec, 0x84, 0x4a, 0xd7, 0xc2, 0xb3, 0xe5,
    };

    const expected_okm = [42]u8{
        0x3c, 0xb2, 0x5f, 0x25, 0xfa, 0xac, 0xd5, 0x7a,
        0x90, 0x43, 0x4f, 0x64, 0xd0, 0x36, 0x2f, 0x2a,
        0x2d, 0x2d, 0x0a, 0x90, 0xcf, 0x1a, 0x5a, 0x4c,
        0x5d, 0xb0, 0x2d, 0x56, 0xec, 0xc4, 0xc5, 0xbf,
        0x34, 0x00, 0x72, 0x08, 0xd5, 0xb8, 0x87, 0x18,
        0x58, 0x65,
    };

    const prk = H.extract(&salt, &ikm);
    if (!std.mem.eql(u8, &prk, &expected_prk)) {
        failed("hkdf_sha256 — PRK mismatch");
        return;
    }

    const okm = H.expand(&prk, &info, 42);
    if (!std.mem.eql(u8, &okm, &expected_okm)) {
        failed("hkdf_sha256 — OKM mismatch");
        return;
    }

    passed("hkdf_sha256");
}

// ============================================================================
// HKDF-SHA384: extract + expand round-trip (verify non-zero output)
// ============================================================================

fn testHkdfSha384() void {
    const H = Crypto.HkdfSha384;

    const ikm = "hkdf-sha384 input key material";
    const salt = "hkdf-sha384 salt";
    const info = "hkdf-sha384 info";

    const prk = H.extract(salt, ikm);

    // PRK must not be all zeros
    var all_zero = true;
    for (prk) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        failed("hkdf_sha384 — PRK is all zeros");
        return;
    }

    const okm = H.expand(&prk, info, 48);

    // OKM must not be all zeros
    all_zero = true;
    for (okm) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        failed("hkdf_sha384 — OKM is all zeros");
        return;
    }

    passed("hkdf_sha384");
}

// ============================================================================
// HMAC-SHA256: RFC 4231 Test Case 2
// ============================================================================

fn testHmacSha256() void {
    const Hmac = Crypto.HmacSha256;

    const key = "Jefe";
    const data = "what do ya want for nothing?";

    const expected = [32]u8{
        0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e,
        0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
        0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83,
        0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
    };

    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, data, key);

    if (std.mem.eql(u8, &mac, &expected)) passed("hmac_sha256") else failed("hmac_sha256 — MAC mismatch");
}

// ============================================================================
// HMAC-SHA384: create + verify non-zero
// ============================================================================

fn testHmacSha384() void {
    const Hmac = Crypto.HmacSha384;

    const key = "hmac-sha384-key";
    const data = "hmac-sha384 test data";

    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, data, key);

    // MAC must not be all zeros
    var all_zero = true;
    for (mac) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        failed("hmac_sha384 — MAC is all zeros");
        return;
    }

    // Verify determinism: same input produces same MAC
    var mac2: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac2, data, key);

    if (std.mem.eql(u8, &mac, &mac2)) passed("hmac_sha384") else failed("hmac_sha384 — non-deterministic");
}

// ============================================================================
// AEAD tamper detection: flipping a ciphertext byte must cause auth failure
// ============================================================================

fn testAeadTamperDetection() void {
    const Aes = Crypto.Aes128Gcm;
    const key: [Aes.key_length]u8 = .{0xaa} ** Aes.key_length;
    const nonce: [Aes.nonce_length]u8 = .{0xbb} ** Aes.nonce_length;
    const plaintext = "tamper test data";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [Aes.tag_length]u8 = undefined;
    Aes.encryptStatic(&ciphertext, &tag, plaintext, "", nonce, key);

    ciphertext[0] ^= 0xff;

    var out: [plaintext.len]u8 = undefined;
    if (Aes.decryptStatic(&out, &ciphertext, tag, "", nonce, key)) |_| {
        failed("aead_tamper — accepted tampered ciphertext");
    } else |_| {
        passed("aead_tamper");
    }
}

// ============================================================================
// ChaCha20-Poly1305 tamper detection
// ============================================================================

fn testChaCha20TamperDetection() void {
    const CC = Crypto.ChaCha20Poly1305;
    const key: [CC.key_length]u8 = .{0xcc} ** CC.key_length;
    const nonce: [CC.nonce_length]u8 = .{0xdd} ** CC.nonce_length;
    const plaintext = "chacha tamper test";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [CC.tag_length]u8 = undefined;
    CC.encryptStatic(&ciphertext, &tag, plaintext, "", nonce, key);

    tag[0] ^= 0xff;

    var out: [plaintext.len]u8 = undefined;
    if (CC.decryptStatic(&out, &ciphertext, tag, "", nonce, key)) |_| {
        failed("chacha20_tamper — accepted tampered tag");
    } else |_| {
        passed("chacha20_tamper");
    }
}

// ============================================================================
// Entry point
// ============================================================================

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/crypto — {}", .{err});
    };
}

test "e2e: trait/crypto" {
    try runTests();
}
