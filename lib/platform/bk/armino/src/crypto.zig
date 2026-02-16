//! Crypto bindings for BK7258 — wraps bk_zig_crypto_helper.c

pub const Error = error{ CryptoError, AuthenticationFailed };

// ============================================================================
// C FFI declarations
// ============================================================================

extern fn bk_zig_rng_fill(buf: [*]u8, len: c_uint) void;
extern fn bk_zig_sha256(input: [*]const u8, len: c_uint, output: *[32]u8) c_int;
extern fn bk_zig_sha384(input: [*]const u8, len: c_uint, output: *[48]u8) c_int;
extern fn bk_zig_sha512(input: [*]const u8, len: c_uint, output: *[64]u8) c_int;
extern fn bk_zig_sha1(input: [*]const u8, len: c_uint, output: *[20]u8) c_int;

// Streaming SHA
pub extern fn bk_zig_sha256_init() c_int;
pub extern fn bk_zig_sha256_update(handle: c_int, data: [*]const u8, len: c_uint) c_int;
pub extern fn bk_zig_sha256_final(handle: c_int, output: *[32]u8) c_int;
pub extern fn bk_zig_sha384_init() c_int;
pub extern fn bk_zig_sha384_update(handle: c_int, data: [*]const u8, len: c_uint) c_int;
pub extern fn bk_zig_sha384_final(handle: c_int, output: *[48]u8) c_int;
pub extern fn bk_zig_sha512_init() c_int;
pub extern fn bk_zig_sha512_update(handle: c_int, data: [*]const u8, len: c_uint) c_int;
pub extern fn bk_zig_sha512_final(handle: c_int, output: *[64]u8) c_int;
pub extern fn bk_zig_sha1_init() c_int;
pub extern fn bk_zig_sha1_update(handle: c_int, data: [*]const u8, len: c_uint) c_int;
pub extern fn bk_zig_sha1_final(handle: c_int, output: *[20]u8) c_int;
extern fn bk_zig_aes_gcm_encrypt(key: [*]const u8, key_len: c_uint, iv: [*]const u8, iv_len: c_uint, aad: [*]const u8, aad_len: c_uint, input: [*]const u8, input_len: c_uint, output: [*]u8, tag: *[16]u8) c_int;
extern fn bk_zig_aes_gcm_decrypt(key: [*]const u8, key_len: c_uint, iv: [*]const u8, iv_len: c_uint, aad: [*]const u8, aad_len: c_uint, input: [*]const u8, input_len: c_uint, output: [*]u8, tag: [*]const u8) c_int;
extern fn bk_zig_hkdf_extract(salt: ?[*]const u8, salt_len: c_uint, ikm: [*]const u8, ikm_len: c_uint, prk: [*]u8, hash_len: c_uint) c_int;
extern fn bk_zig_hkdf_expand(prk: [*]const u8, prk_len: c_uint, info: [*]const u8, info_len: c_uint, okm: [*]u8, okm_len: c_uint) c_int;
extern fn bk_zig_hmac(hash_len: c_uint, key: [*]const u8, key_len: c_uint, input: [*]const u8, input_len: c_uint, output: [*]u8) c_int;
pub extern fn bk_zig_hmac_init(hash_len: c_uint, key: [*]const u8, key_len: c_uint) c_int;
pub extern fn bk_zig_hmac_update(handle: c_int, data: [*]const u8, len: c_uint) c_int;
pub extern fn bk_zig_hmac_final(handle: c_int, output: [*]u8) c_int;
extern fn bk_zig_p256_keypair(seed: *const [32]u8, sk_out: *[32]u8, pk_out: *[65]u8) c_int;
extern fn bk_zig_p256_ecdh(sk: *const [32]u8, pk: *const [65]u8, out: *[32]u8) c_int;
extern fn bk_zig_p256_compute_public(sk: *const [32]u8, pk_out: *[65]u8) c_int;
extern fn bk_zig_p384_keypair(seed: *const [48]u8, sk_out: *[48]u8, pk_out: *[97]u8) c_int;
extern fn bk_zig_p384_ecdh(sk: *const [48]u8, pk: *const [97]u8, out: *[48]u8) c_int;
extern fn bk_zig_ecdsa_p256_verify(hash: *const [32]u8, r: *const [32]u8, s: *const [32]u8, pk: *const [65]u8) c_int;
extern fn bk_zig_ecdsa_p384_verify(hash: *const [48]u8, r: *const [48]u8, s: *const [48]u8, pk: *const [97]u8) c_int;
extern fn bk_zig_x25519_keypair(seed: *const [32]u8, sk_out: *[32]u8, pk_out: *[32]u8) c_int;
extern fn bk_zig_x25519_scalarmult(sk: *const [32]u8, pk: *const [32]u8, out: *[32]u8) c_int;

// ============================================================================
// Public Zig API
// ============================================================================

pub fn rngFill(buf: []u8) void {
    bk_zig_rng_fill(buf.ptr, @intCast(buf.len));
}

pub fn sha256(input: []const u8, output: *[32]u8) !void {
    if (bk_zig_sha256(input.ptr, @intCast(input.len), output) != 0) return error.CryptoError;
}

pub fn sha384(input: []const u8, output: *[48]u8) !void {
    if (bk_zig_sha384(input.ptr, @intCast(input.len), output) != 0) return error.CryptoError;
}

pub fn sha512(input: []const u8, output: *[64]u8) !void {
    if (bk_zig_sha512(input.ptr, @intCast(input.len), output) != 0) return error.CryptoError;
}

pub fn sha1(input: []const u8, output: *[20]u8) !void {
    if (bk_zig_sha1(input.ptr, @intCast(input.len), output) != 0) return error.CryptoError;
}

pub fn aesGcmEncrypt(
    key: []const u8,
    iv: []const u8,
    aad: []const u8,
    input: []const u8,
    output: []u8,
    tag: *[16]u8,
) !void {
    if (bk_zig_aes_gcm_encrypt(
        key.ptr,
        @intCast(key.len),
        iv.ptr,
        @intCast(iv.len),
        aad.ptr,
        @intCast(aad.len),
        input.ptr,
        @intCast(input.len),
        output.ptr,
        tag,
    ) != 0) return error.CryptoError;
}

pub fn aesGcmDecrypt(
    key: []const u8,
    iv: []const u8,
    aad: []const u8,
    input: []const u8,
    output: []u8,
    tag: []const u8,
) !void {
    const ret = bk_zig_aes_gcm_decrypt(
        key.ptr,
        @intCast(key.len),
        iv.ptr,
        @intCast(iv.len),
        aad.ptr,
        @intCast(aad.len),
        input.ptr,
        @intCast(input.len),
        output.ptr,
        tag.ptr,
    );
    if (ret != 0) return error.AuthenticationFailed;
}

pub fn hkdfExtract(comptime hash_len: usize, salt: ?[]const u8, ikm: []const u8) ![hash_len]u8 {
    var prk: [hash_len]u8 = undefined;
    const s_ptr = if (salt) |s| s.ptr else null;
    const s_len: c_uint = if (salt) |s| @intCast(s.len) else 0;
    if (bk_zig_hkdf_extract(s_ptr, s_len, ikm.ptr, @intCast(ikm.len), &prk, hash_len) != 0)
        return error.CryptoError;
    return prk;
}

pub fn hkdfExpand(comptime prk_len: usize, prk: *const [prk_len]u8, info: []const u8, comptime okm_len: usize) ![okm_len]u8 {
    var okm: [okm_len]u8 = undefined;
    if (bk_zig_hkdf_expand(prk, prk_len, info.ptr, @intCast(info.len), &okm, okm_len) != 0)
        return error.CryptoError;
    return okm;
}

pub fn hmac(comptime hash_len: usize, key: []const u8, input: []const u8) ![hash_len]u8 {
    var output: [hash_len]u8 = undefined;
    if (bk_zig_hmac(hash_len, key.ptr, @intCast(key.len), input.ptr, @intCast(input.len), &output) != 0)
        return error.CryptoError;
    return output;
}

pub fn p256Keypair(seed: [32]u8) !struct { secret_key: [32]u8, public_key: [65]u8 } {
    var sk: [32]u8 = undefined;
    var pk: [65]u8 = undefined;
    if (bk_zig_p256_keypair(&seed, &sk, &pk) != 0) return error.CryptoError;
    return .{ .secret_key = sk, .public_key = pk };
}

pub fn p256Ecdh(sk: [32]u8, pk: [65]u8) ![32]u8 {
    var out: [32]u8 = undefined;
    if (bk_zig_p256_ecdh(&sk, &pk, &out) != 0) return error.CryptoError;
    return out;
}

pub fn p256ComputePublic(sk: [32]u8) ![65]u8 {
    var pk: [65]u8 = undefined;
    if (bk_zig_p256_compute_public(&sk, &pk) != 0) return error.CryptoError;
    return pk;
}

pub fn p384Keypair(seed: [48]u8) !struct { secret_key: [48]u8, public_key: [97]u8 } {
    var sk: [48]u8 = undefined;
    var pk: [97]u8 = undefined;
    if (bk_zig_p384_keypair(&seed, &sk, &pk) != 0) return error.CryptoError;
    return .{ .secret_key = sk, .public_key = pk };
}

pub fn p384Ecdh(sk: [48]u8, pk: [97]u8) ![48]u8 {
    var out: [48]u8 = undefined;
    if (bk_zig_p384_ecdh(&sk, &pk, &out) != 0) return error.CryptoError;
    return out;
}

pub fn x25519Keypair(seed: [32]u8) !struct { secret_key: [32]u8, public_key: [32]u8 } {
    var sk: [32]u8 = undefined;
    var pk: [32]u8 = undefined;
    if (bk_zig_x25519_keypair(&seed, &sk, &pk) != 0) return error.CryptoError;
    return .{ .secret_key = sk, .public_key = pk };
}

pub fn x25519Scalarmult(sk: [32]u8, pk: [32]u8) ![32]u8 {
    var out: [32]u8 = undefined;
    if (bk_zig_x25519_scalarmult(&sk, &pk, &out) != 0) return error.CryptoError;
    return out;
}

pub fn ecdsaP256Verify(hash: [32]u8, r: [32]u8, s: [32]u8, pk: [65]u8) !void {
    if (bk_zig_ecdsa_p256_verify(&hash, &r, &s, &pk) != 0) return error.CryptoError;
}

pub fn ecdsaP384Verify(hash: [48]u8, r: [48]u8, s: [48]u8, pk: [97]u8) !void {
    if (bk_zig_ecdsa_p384_verify(&hash, &r, &s, &pk) != 0) return error.CryptoError;
}
