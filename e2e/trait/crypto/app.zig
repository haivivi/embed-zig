//! e2e: trait/crypto — Verify SHA256, AES-128-GCM, X25519
//!
//! Tests:
//!   1. SHA256 known-answer test (hash of "abc")
//!   2. AES-128-GCM encrypt + decrypt round-trip
//!   3. X25519 Diffie-Hellman key exchange

const std = @import("std");
const platform = @import("platform.zig");
const log = platform.log;
const Crypto = platform.Crypto;

fn runTests() !void {
    log.info("[e2e] START: trait/crypto", .{});

    try testSha256();
    try testAes128Gcm();
    try testX25519();

    log.info("[e2e] PASS: trait/crypto", .{});
}

// Test 1: SHA256 of "abc" == known hash
fn testSha256() !void {
    var hasher = Crypto.Sha256.init();
    hasher.update("abc");
    const digest = hasher.final();

    // SHA256("abc") = ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 96177a9c b410ff61 f20015ad
    const expected = [32]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };

    if (!std.mem.eql(u8, &digest, &expected)) {
        log.err("[e2e] FAIL: trait/crypto/sha256 — digest mismatch", .{});
        return error.Sha256Mismatch;
    }
    log.info("[e2e] PASS: trait/crypto/sha256", .{});
}

// Test 2: AES-128-GCM encrypt then decrypt, verify plaintext round-trip
fn testAes128Gcm() !void {
    const Aes = Crypto.Aes128Gcm;
    const key: [Aes.key_length]u8 = .{0x42} ** Aes.key_length;
    const nonce: [Aes.nonce_length]u8 = .{0x01} ** Aes.nonce_length;
    const aad = "additional data";
    const plaintext = "hello crypto e2e";

    // Encrypt
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [Aes.tag_length]u8 = undefined;
    Aes.encryptStatic(&ciphertext, &tag, plaintext, aad, nonce, key);

    // Ciphertext should differ from plaintext
    if (std.mem.eql(u8, &ciphertext, plaintext)) {
        log.err("[e2e] FAIL: trait/crypto/aes128gcm — ciphertext equals plaintext", .{});
        return error.AesNotEncrypted;
    }

    // Decrypt
    var decrypted: [plaintext.len]u8 = undefined;
    Aes.decryptStatic(&decrypted, &ciphertext, tag, aad, nonce, key) catch {
        log.err("[e2e] FAIL: trait/crypto/aes128gcm — decryption failed", .{});
        return error.AesDecryptFailed;
    };

    if (!std.mem.eql(u8, &decrypted, plaintext)) {
        log.err("[e2e] FAIL: trait/crypto/aes128gcm — decrypted != plaintext", .{});
        return error.AesRoundtripMismatch;
    }
    log.info("[e2e] PASS: trait/crypto/aes128gcm", .{});
}

// Test 3: X25519 DH — two key pairs produce same shared secret
fn testX25519() !void {
    const X = Crypto.X25519;
    const seed_a: [32]u8 = .{0x01} ** 32;
    const seed_b: [32]u8 = .{0x02} ** 32;

    const kp_a = X.KeyPair.generateDeterministic(seed_a) catch {
        log.err("[e2e] FAIL: trait/crypto/x25519 — keygen A failed", .{});
        return error.X25519KeygenFailed;
    };
    const kp_b = X.KeyPair.generateDeterministic(seed_b) catch {
        log.err("[e2e] FAIL: trait/crypto/x25519 — keygen B failed", .{});
        return error.X25519KeygenFailed;
    };

    // A computes shared = scalarmult(a_secret, b_public)
    const shared_a = X.scalarmult(kp_a.secret_key, kp_b.public_key) catch {
        log.err("[e2e] FAIL: trait/crypto/x25519 — DH A failed", .{});
        return error.X25519DhFailed;
    };
    // B computes shared = scalarmult(b_secret, a_public)
    const shared_b = X.scalarmult(kp_b.secret_key, kp_a.public_key) catch {
        log.err("[e2e] FAIL: trait/crypto/x25519 — DH B failed", .{});
        return error.X25519DhFailed;
    };

    if (!std.mem.eql(u8, &shared_a, &shared_b)) {
        log.err("[e2e] FAIL: trait/crypto/x25519 — shared secrets differ", .{});
        return error.X25519SharedMismatch;
    }

    // Shared secret should not be all zeros
    var all_zero = true;
    for (shared_a) |b| {
        if (b != 0) { all_zero = false; break; }
    }
    if (all_zero) {
        log.err("[e2e] FAIL: trait/crypto/x25519 — shared secret all zeros", .{});
        return error.X25519ZeroSecret;
    }
    log.info("[e2e] PASS: trait/crypto/x25519", .{});
}

pub fn entry(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/crypto — {}", .{err});
    };
}

test "e2e: trait/crypto" {
    try runTests();
}
