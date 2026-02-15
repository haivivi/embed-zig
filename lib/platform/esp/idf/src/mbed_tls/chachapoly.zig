//! ChaCha20-Poly1305 wrapper for mbedTLS C helper
//!
//! This module wraps the C helper functions that implement ChaCha20-Poly1305
//! using mbedTLS's chachapoly module (software implementation).

extern fn chachapoly_encrypt(
    key: *const [32]u8,
    nonce: *const [12]u8,
    aad: ?[*]const u8,
    aad_len: usize,
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
    tag: *[16]u8,
) c_int;

extern fn chachapoly_decrypt(
    key: *const [32]u8,
    nonce: *const [12]u8,
    aad: ?[*]const u8,
    aad_len: usize,
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
    tag: *const [16]u8,
) c_int;

pub const Error = error{
    AuthenticationFailed,
    CryptoError,
};

pub const key_length = 32;
pub const nonce_length = 12;
pub const tag_length = 16;

/// Encrypt plaintext and generate authentication tag
pub fn encrypt(
    ciphertext: []u8,
    tag: *[tag_length]u8,
    plaintext: []const u8,
    aad: []const u8,
    nonce: [nonce_length]u8,
    key: [key_length]u8,
) void {
    const ret = chachapoly_encrypt(
        &key,
        &nonce,
        if (aad.len > 0) aad.ptr else null,
        aad.len,
        plaintext.ptr,
        plaintext.len,
        ciphertext.ptr,
        tag,
    );
    if (ret != 0) @panic("chachapoly_encrypt failed");
}

/// Decrypt ciphertext and verify authentication tag
pub fn decrypt(
    plaintext: []u8,
    ciphertext: []const u8,
    tag: [tag_length]u8,
    aad: []const u8,
    nonce: [nonce_length]u8,
    key: [key_length]u8,
) Error!void {
    const ret = chachapoly_decrypt(
        &key,
        &nonce,
        if (aad.len > 0) aad.ptr else null,
        aad.len,
        ciphertext.ptr,
        ciphertext.len,
        plaintext.ptr,
        &tag,
    );

    if (ret == -0x0054) { // MBEDTLS_ERR_CHACHAPOLY_AUTH_FAILED
        return error.AuthenticationFailed;
    }
    if (ret != 0) {
        return error.CryptoError;
    }
}
