//! AES-GCM wrapper for mbedTLS C helper
//!
//! This module wraps the C helper functions that implement AES-GCM
//! using mbedTLS's base AES cipher (which is hardware accelerated).
//! This avoids dependency on the mbedTLS GCM module which may not
//! be enabled in some ESP-IDF configurations.

// Extern declarations for C helper functions
extern fn aes_gcm_encrypt(
    key: [*]const u8,
    key_len: usize,
    iv: [*]const u8,
    iv_len: usize,
    aad: ?[*]const u8,
    aad_len: usize,
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
    tag: *[16]u8,
) c_int;

extern fn aes_gcm_decrypt(
    key: [*]const u8,
    key_len: usize,
    iv: [*]const u8,
    iv_len: usize,
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

/// AES-128-GCM
pub const Aes128 = struct {
    pub const key_length = 16;
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
        const ret = aes_gcm_encrypt(
            &key,
            key_length,
            &nonce,
            nonce_length,
            if (aad.len > 0) aad.ptr else null,
            aad.len,
            plaintext.ptr,
            plaintext.len,
            ciphertext.ptr,
            tag,
        );
        if (ret != 0) @panic("aes_gcm_encrypt failed");
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
        const ret = aes_gcm_decrypt(
            &key,
            key_length,
            &nonce,
            nonce_length,
            if (aad.len > 0) aad.ptr else null,
            aad.len,
            ciphertext.ptr,
            ciphertext.len,
            plaintext.ptr,
            &tag,
        );

        if (ret == -0x0012) { // MBEDTLS_ERR_GCM_AUTH_FAILED
            return error.AuthenticationFailed;
        }
        if (ret != 0) {
            return error.CryptoError;
        }
    }
};

/// AES-256-GCM
pub const Aes256 = struct {
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
        const ret = aes_gcm_encrypt(
            &key,
            key_length,
            &nonce,
            nonce_length,
            if (aad.len > 0) aad.ptr else null,
            aad.len,
            plaintext.ptr,
            plaintext.len,
            ciphertext.ptr,
            tag,
        );
        if (ret != 0) @panic("aes_gcm_encrypt failed");
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
        const ret = aes_gcm_decrypt(
            &key,
            key_length,
            &nonce,
            nonce_length,
            if (aad.len > 0) aad.ptr else null,
            aad.len,
            ciphertext.ptr,
            ciphertext.len,
            plaintext.ptr,
            &tag,
        );

        if (ret == -0x0012) { // MBEDTLS_ERR_GCM_AUTH_FAILED
            return error.AuthenticationFailed;
        }
        if (ret != 0) {
            return error.CryptoError;
        }
    }
};
