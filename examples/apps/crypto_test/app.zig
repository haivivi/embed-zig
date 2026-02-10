//! Crypto Primitives Test — verifies each crypto operation independently
//!
//! Tests: RNG, SHA-256, HMAC-SHA256, AES-128-GCM, P256 keypair/ECDH

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;
const Crypto = Board.crypto;

fn testRng() bool {
    log.info("[RNG] Testing...", .{});
    var buf: [32]u8 = .{0} ** 32;
    Crypto.Rng.fill(&buf);
    // Check not all zeros
    var nonzero: u32 = 0;
    for (buf) |b| { if (b != 0) nonzero += 1; }
    if (nonzero < 4) {
        log.err("[RNG] FAIL: only {} non-zero bytes in 32", .{nonzero});
        return false;
    }
    log.info("[RNG] PASS ({} non-zero bytes)", .{nonzero});
    return true;
}

fn testSha256() bool {
    log.info("[SHA256] Testing...", .{});
    // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const expected = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };

    // Test one-shot
    var out: [32]u8 = undefined;
    Crypto.Sha256.hash("", &out, .{});
    if (!std.mem.eql(u8, &out, &expected)) {
        log.err("[SHA256] one-shot FAIL", .{});
        return false;
    }
    log.info("[SHA256] one-shot PASS", .{});

    // Test streaming
    var ctx = Crypto.Sha256.init();
    ctx.update("hello");
    ctx.update(" world");
    const stream_out = ctx.final();
    // SHA-256("hello world") = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
    const expected2 = [_]u8{
        0xb9, 0x4d, 0x27, 0xb9, 0x93, 0x4d, 0x3e, 0x08, 0xa5, 0x2e, 0x52, 0xd7, 0xda, 0x7d, 0xab, 0xfa,
        0xc4, 0x84, 0xef, 0xe3, 0x7a, 0x53, 0x80, 0xee, 0x90, 0x88, 0xf7, 0xac, 0xe2, 0xef, 0xcd, 0xe9,
    };
    if (!std.mem.eql(u8, &stream_out, &expected2)) {
        log.err("[SHA256] streaming FAIL", .{});
        return false;
    }
    log.info("[SHA256] streaming PASS", .{});
    return true;
}

fn testHmacSha256() bool {
    log.info("[HMAC] Testing...", .{});
    // HMAC-SHA256(key="key", data="hello") = 9307b3b915efb5171ff14d8cb55fbcc798c6c0ef1456d66ded1a6aa723a58b7b
    const expected = [_]u8{
        0x93, 0x07, 0xb3, 0xb9, 0x15, 0xef, 0xb5, 0x17, 0x1f, 0xf1, 0x4d, 0x8c, 0xb5, 0x5f, 0xbc, 0xc7,
        0x98, 0xc6, 0xc0, 0xef, 0x14, 0x56, 0xd6, 0x6d, 0xed, 0x1a, 0x6a, 0xa7, 0x23, 0xa5, 0x8b, 0x7b,
    };

    // One-shot
    var out: [32]u8 = undefined;
    Crypto.HmacSha256.create(&out, "hello", "key");
    if (!std.mem.eql(u8, &out, &expected)) {
        log.err("[HMAC] one-shot FAIL", .{});
        return false;
    }
    log.info("[HMAC] one-shot PASS", .{});

    // Streaming
    var ctx = Crypto.HmacSha256.init("key");
    ctx.update("hel");
    ctx.update("lo");
    const stream_out = ctx.final();
    if (!std.mem.eql(u8, &stream_out, &expected)) {
        log.err("[HMAC] streaming FAIL", .{});
        return false;
    }
    log.info("[HMAC] streaming PASS", .{});
    return true;
}

fn testAesGcm() bool {
    log.info("[AES-GCM] Testing...", .{});
    const key = [16]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const nonce = [12]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b };
    const plaintext = "Hello AES-GCM!";
    var ciphertext: [14]u8 = undefined;
    var tag: [16]u8 = undefined;

    // Encrypt
    Crypto.Aes128Gcm.encryptStatic(&ciphertext, &tag, plaintext, "", nonce, key);
    log.info("[AES-GCM] encrypt done", .{});

    // Decrypt
    var decrypted: [14]u8 = undefined;
    Crypto.Aes128Gcm.decryptStatic(&decrypted, &ciphertext, tag, "", nonce, key) catch {
        log.err("[AES-GCM] decrypt FAIL (auth failed)", .{});
        return false;
    };

    if (!std.mem.eql(u8, &decrypted, plaintext)) {
        log.err("[AES-GCM] decrypt FAIL (data mismatch)", .{});
        return false;
    }
    log.info("[AES-GCM] PASS", .{});
    return true;
}

fn testP256() bool {
    log.info("[P256] Testing keypair generation...", .{});
    // Generate a keypair from random seed
    var seed: [32]u8 = undefined;
    Crypto.Rng.fill(&seed);

    const kp = Crypto.P256.KeyPair.generateDeterministic(seed) catch |err| {
        log.err("[P256] keypair generation FAIL: {}", .{err});
        return false;
    };

    // Verify public key starts with 0x04 (uncompressed)
    if (kp.public_key[0] != 0x04) {
        log.err("[P256] FAIL: public key doesn't start with 0x04", .{});
        return false;
    }
    log.info("[P256] keypair PASS (pk[0]=0x04, sk and pk generated)", .{});

    // Test ECDH
    log.info("[P256] Testing ECDH...", .{});
    var seed2: [32]u8 = undefined;
    Crypto.Rng.fill(&seed2);
    const kp2 = Crypto.P256.KeyPair.generateDeterministic(seed2) catch |err| {
        log.err("[P256] keypair2 FAIL: {}", .{err});
        return false;
    };

    const shared1 = Crypto.P256.ecdh(kp.secret_key, kp2.public_key) catch |err| {
        log.err("[P256] ECDH(1,2) FAIL: {}", .{err});
        return false;
    };
    const shared2 = Crypto.P256.ecdh(kp2.secret_key, kp.public_key) catch |err| {
        log.err("[P256] ECDH(2,1) FAIL: {}", .{err});
        return false;
    };

    if (!std.mem.eql(u8, &shared1, &shared2)) {
        log.err("[P256] ECDH FAIL: shared secrets don't match", .{});
        return false;
    }
    log.info("[P256] ECDH PASS (shared secrets match)", .{});
    return true;
}

fn testHkdf() bool {
    log.info("[HKDF] Testing...", .{});
    // HKDF-SHA256 extract + expand
    const ikm = "input keying material";
    const salt = "salt value";
    const prk = Crypto.HkdfSha256.extract(salt, ikm);

    // PRK should not be all zeros
    var nonzero: u32 = 0;
    for (prk) |b| { if (b != 0) nonzero += 1; }
    if (nonzero < 4) {
        log.err("[HKDF] extract FAIL: mostly zeros", .{});
        return false;
    }
    log.info("[HKDF] extract PASS", .{});

    const okm = Crypto.HkdfSha256.expand(&prk, "info", 32);
    nonzero = 0;
    for (okm) |b| { if (b != 0) nonzero += 1; }
    if (nonzero < 4) {
        log.err("[HKDF] expand FAIL: mostly zeros", .{});
        return false;
    }
    log.info("[HKDF] expand PASS", .{});
    return true;
}

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("  Crypto Primitives Test", .{});
    log.info("==========================================", .{});

    var passed: u32 = 0;
    var total: u32 = 0;

    total += 1; if (testRng()) passed += 1;
    Board.time.sleepMs(100);
    total += 1; if (testSha256()) passed += 1;
    Board.time.sleepMs(100);
    total += 1; if (testHmacSha256()) passed += 1;
    Board.time.sleepMs(100);
    total += 1; if (testAesGcm()) passed += 1;
    Board.time.sleepMs(100);
    total += 1; if (testHkdf()) passed += 1;
    Board.time.sleepMs(100);
    total += 1; if (testP256()) passed += 1;

    log.info("", .{});
    log.info("==========================================", .{});
    log.info("  TOTAL: {}/{} PASSED", .{ passed, total });
    log.info("==========================================", .{});

    while (true) { Board.time.sleepMs(10000); }
}
