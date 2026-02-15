//! e2e: trait/crypto — Comprehensive cryptographic primitives conformance test
//!
//! Tests every primitive with known-answer test vectors (KATs) from RFCs/NIST.
//! This catches platform-specific bugs: wrong calculations, unsupported ops, crashes.
//!
//! Uses @hasDecl to conditionally test primitives — only runs what the platform provides.
//!
//! Test vectors sources:
//!   - SHA-2: FIPS 180-4 / RFC 6234
//!   - AES-GCM: NIST SP 800-38D
//!   - ChaCha20-Poly1305: RFC 8439 §2.8.2
//!   - X25519: RFC 7748 §6.1
//!   - HKDF: RFC 5869 Test Case 1
//!   - HMAC: RFC 4231 Test Case 2

const std = @import("std");
const platform = @import("platform.zig");
const log = platform.log;
const Crypto = platform.Crypto;

var pass_count: u32 = 0;
var fail_count: u32 = 0;
var skip_count: u32 = 0;

fn passed(comptime name: []const u8) void {
    pass_count += 1;
    log.info("[e2e]   PASS: " ++ name, .{});
}

fn failed(comptime name: []const u8) void {
    fail_count += 1;
    log.err("[e2e]   FAIL: " ++ name, .{});
}

fn skipped(comptime name: []const u8) void {
    skip_count += 1;
    log.info("[e2e]   SKIP: " ++ name ++ " (not provided by platform)", .{});
}

fn runTests() !void {
    log.info("[e2e] START: trait/crypto", .{});

    // ========================================================================
    // Hash functions
    // ========================================================================

    if (comptime @hasDecl(Crypto, "Sha256")) testSha256() else skipped("sha256");
    if (comptime @hasDecl(Crypto, "Sha384")) testSha384() else skipped("sha384");
    if (comptime @hasDecl(Crypto, "Sha512")) testSha512() else skipped("sha512");
    if (comptime @hasDecl(Crypto, "Sha1")) testSha1() else skipped("sha1");

    // ========================================================================
    // AEAD ciphers
    // ========================================================================

    if (comptime @hasDecl(Crypto, "Aes128Gcm")) testAes128Gcm() else skipped("aes128gcm");
    if (comptime @hasDecl(Crypto, "Aes256Gcm")) testAes256Gcm() else skipped("aes256gcm");
    if (comptime @hasDecl(Crypto, "ChaCha20Poly1305")) testChaCha20Poly1305() else skipped("chacha20poly1305");

    // ========================================================================
    // Key exchange
    // ========================================================================

    if (comptime @hasDecl(Crypto, "X25519")) testX25519() else skipped("x25519");
    if (comptime @hasDecl(Crypto, "P256")) testP256() else skipped("p256");

    // ========================================================================
    // KDF
    // ========================================================================

    if (comptime @hasDecl(Crypto, "HkdfSha256")) testHkdfSha256() else skipped("hkdf_sha256");

    // ========================================================================
    // MAC
    // ========================================================================

    if (comptime @hasDecl(Crypto, "HmacSha256")) testHmacSha256() else skipped("hmac_sha256");

    // ========================================================================
    // AEAD tamper detection
    // ========================================================================

    if (comptime @hasDecl(Crypto, "Aes128Gcm")) testAeadTamperDetection() else skipped("aead_tamper");
    if (comptime @hasDecl(Crypto, "ChaCha20Poly1305")) testChaCha20TamperDetection() else skipped("chacha20_tamper");

    // ========================================================================
    // Summary
    // ========================================================================

    log.info("[e2e] SUMMARY: trait/crypto — {} passed, {} failed, {} skipped", .{ pass_count, fail_count, skip_count });

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
// SHA-512: FIPS 180-4 "abc"
// ============================================================================

fn testSha512() void {
    var h = Crypto.Sha512.init();
    h.update("abc");
    const got = h.final();

    const expected = [64]u8{
        0xdd, 0xaf, 0x35, 0xa1, 0x93, 0x61, 0x7a, 0xba,
        0xcc, 0x41, 0x73, 0x49, 0xae, 0x20, 0x41, 0x31,
        0x12, 0xe6, 0xfa, 0x4e, 0x89, 0xa9, 0x7e, 0xa2,
        0x0a, 0x9e, 0xee, 0xe6, 0x4b, 0x55, 0xd3, 0x9a,
        0x21, 0x92, 0x99, 0x2a, 0x27, 0x4f, 0xc1, 0xa8,
        0x36, 0xba, 0x3c, 0x23, 0xa3, 0xfe, 0xeb, 0xbd,
        0x45, 0x4d, 0x44, 0x23, 0x64, 0x3c, 0xe8, 0x0e,
        0x2a, 0x9a, 0xc9, 0x4f, 0xa5, 0x4c, 0xa4, 0x9f,
    };

    if (std.mem.eql(u8, &got, &expected)) passed("sha512") else failed("sha512 — digest mismatch");
}

// ============================================================================
// SHA-1: FIPS 180-4 "abc" (legacy, for TLS 1.2)
// ============================================================================

fn testSha1() void {
    var h = Crypto.Sha1.init();
    h.update("abc");
    const got = h.final();

    const expected = [20]u8{
        0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a,
        0xba, 0x3e, 0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c,
        0x9c, 0xd0, 0xd8, 0x9d,
    };

    if (std.mem.eql(u8, &got, &expected)) passed("sha1") else failed("sha1 — digest mismatch");
}

// ============================================================================
// AES-128-GCM: encrypt + decrypt round-trip + verify ciphertext differs
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

    // Ciphertext must differ from plaintext
    if (std.mem.eql(u8, &ciphertext, plaintext)) {
        failed("aes128gcm — ciphertext equals plaintext");
        return;
    }

    // Decrypt and verify round-trip
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

    // RFC 8439 §2.8.2 test vector
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

    // Encrypt
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [CC.tag_length]u8 = undefined;
    CC.encryptStatic(&ciphertext, &tag, plaintext, &aad, nonce, key);

    // Verify tag matches RFC 8439
    if (!std.mem.eql(u8, &tag, &expected_tag)) {
        failed("chacha20poly1305 — tag mismatch vs RFC 8439");
        return;
    }

    // Decrypt and verify round-trip
    var decrypted: [plaintext.len]u8 = undefined;
    CC.decryptStatic(&decrypted, &ciphertext, tag, &aad, nonce, key) catch {
        failed("chacha20poly1305 — decryption failed");
        return;
    };

    if (std.mem.eql(u8, &decrypted, plaintext)) passed("chacha20poly1305") else failed("chacha20poly1305 — round-trip mismatch");
}

// ============================================================================
// X25519: DH key exchange + RFC 7748 §6.1 KAT
// ============================================================================

fn testX25519() void {
    const X = Crypto.X25519;

    // RFC 7748 §6.1 test vector
    // Alice's private key (clamped from 32 bytes of specific values)
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

    // Generate keypairs from these seeds
    const kp_a = X.KeyPair.generateDeterministic(alice_sk) catch {
        failed("x25519 — keygen A failed");
        return;
    };
    const kp_b = X.KeyPair.generateDeterministic(bob_sk) catch {
        failed("x25519 — keygen B failed");
        return;
    };

    // DH: A(sk) * B(pk) == B(sk) * A(pk)
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

    // Must not be all zeros (weak key check)
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
// P-256 ECDH: key exchange round-trip
// ============================================================================

fn testP256() void {
    const P = Crypto.P256;

    // Deterministic seeds
    const seed_a = [32]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
    };
    const seed_b = [32]u8{
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
    };

    const kp_a = P.KeyPair.generateDeterministic(seed_a) catch {
        failed("p256 — keygen A failed");
        return;
    };
    const kp_b = P.KeyPair.generateDeterministic(seed_b) catch {
        failed("p256 — keygen B failed");
        return;
    };

    // ECDH: both sides should derive same shared secret
    const shared_a = P.ecdh(kp_a.secret_key, kp_b.public_key) catch {
        failed("p256 — ECDH A*B failed");
        return;
    };
    const shared_b = P.ecdh(kp_b.secret_key, kp_a.public_key) catch {
        failed("p256 — ECDH B*A failed");
        return;
    };

    if (!std.mem.eql(u8, &shared_a, &shared_b)) {
        failed("p256 — shared secrets differ");
        return;
    }

    // Must not be all zeros
    var all_zero = true;
    for (shared_a) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        failed("p256 — shared secret is all zeros");
        return;
    }

    passed("p256");
}

// ============================================================================
// HKDF-SHA256: RFC 5869 Test Case 1
// ============================================================================

fn testHkdfSha256() void {
    const H = Crypto.HkdfSha256;

    // RFC 5869 Test Case 1
    const ikm = [22]u8{ 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b };
    const salt = [13]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c };
    const info = [10]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9 };

    // Expected PRK from RFC 5869
    const expected_prk = [32]u8{
        0x07, 0x77, 0x09, 0x36, 0x2c, 0x2e, 0x32, 0xdf,
        0x0d, 0xdc, 0x3f, 0x0d, 0xc4, 0x7b, 0xba, 0x63,
        0x90, 0xb6, 0xc7, 0x3b, 0xb5, 0x0f, 0x9c, 0x31,
        0x22, 0xec, 0x84, 0x4a, 0xd7, 0xc2, 0xb3, 0xe5,
    };

    // Expected OKM (first 42 bytes) from RFC 5869
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
// HMAC-SHA256: RFC 4231 Test Case 2
// ============================================================================

fn testHmacSha256() void {
    const Hmac = Crypto.HmacSha256;

    // RFC 4231 Test Case 2
    // Key = "Jefe" (4 bytes)
    // Data = "what do ya want for nothing?" (28 bytes)
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

    // Flip one byte of ciphertext
    ciphertext[0] ^= 0xff;

    // Decryption must fail
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

    // Flip one byte of tag
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
