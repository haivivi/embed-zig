//! mbedTLS C API Bindings
//!
//! Low-level Zig bindings for mbedTLS cryptographic library.
//! Used by ESP-IDF for hardware-accelerated crypto on ESP32.
//!
//! This file provides raw C type and function exports.
//! Higher-level Zig wrappers are in impl/crypto/suite.zig.

const c = @cImport({
    // Hash functions
    @cInclude("mbedtls/sha256.h");
    @cInclude("mbedtls/sha512.h");
    @cInclude("mbedtls/sha1.h");

    // AEAD
    @cInclude("mbedtls/gcm.h");
    @cInclude("mbedtls/chachapoly.h");

    // ECC / Key Exchange
    @cInclude("mbedtls/ecdh.h");
    @cInclude("mbedtls/ecp.h");
    @cInclude("mbedtls/ecdsa.h");
    @cInclude("mbedtls/bignum.h");
    @cInclude("mbedtls/ctr_drbg.h");
    @cInclude("mbedtls/entropy.h");

    // KDF
    @cInclude("mbedtls/hkdf.h");

    // MAC
    @cInclude("mbedtls/md.h");

    // X.509 Certificates
    @cInclude("mbedtls/x509_crt.h");
    @cInclude("mbedtls/x509.h");

    // Cipher (for ID constants)
    @cInclude("mbedtls/cipher.h");
});

// ============================================================================
// Hash Functions - SHA-256
// ============================================================================

pub const sha256_context = c.mbedtls_sha256_context;

pub const sha256_init = c.mbedtls_sha256_init;
pub const sha256_free = c.mbedtls_sha256_free;
pub const sha256_starts = c.mbedtls_sha256_starts;
pub const sha256_update = c.mbedtls_sha256_update;
pub const sha256_finish = c.mbedtls_sha256_finish;
pub const sha256_clone = c.mbedtls_sha256_clone;

// One-shot hash
pub const sha256_hash = c.mbedtls_sha256;

// ============================================================================
// Hash Functions - SHA-512 (also used for SHA-384)
// ============================================================================

pub const sha512_context = c.mbedtls_sha512_context;

pub const sha512_init = c.mbedtls_sha512_init;
pub const sha512_free = c.mbedtls_sha512_free;
pub const sha512_starts = c.mbedtls_sha512_starts;
pub const sha512_update = c.mbedtls_sha512_update;
pub const sha512_finish = c.mbedtls_sha512_finish;
pub const sha512_clone = c.mbedtls_sha512_clone;

// One-shot hash
pub const sha512_hash = c.mbedtls_sha512;

// ============================================================================
// Hash Functions - SHA-1 (legacy, for TLS 1.2)
// ============================================================================

pub const sha1_context = c.mbedtls_sha1_context;

pub const sha1_init = c.mbedtls_sha1_init;
pub const sha1_free = c.mbedtls_sha1_free;
pub const sha1_starts = c.mbedtls_sha1_starts;
pub const sha1_update = c.mbedtls_sha1_update;
pub const sha1_finish = c.mbedtls_sha1_finish;

// One-shot hash
pub const sha1_hash = c.mbedtls_sha1;

// ============================================================================
// AEAD - GCM (AES-GCM)
// ============================================================================

pub const gcm_context = c.mbedtls_gcm_context;

pub const gcm_init = c.mbedtls_gcm_init;
pub const gcm_free = c.mbedtls_gcm_free;
pub const gcm_setkey = c.mbedtls_gcm_setkey;
pub const gcm_crypt_and_tag = c.mbedtls_gcm_crypt_and_tag;
pub const gcm_auth_decrypt = c.mbedtls_gcm_auth_decrypt;

// Cipher IDs for gcm_setkey
pub const CIPHER_ID_AES = c.MBEDTLS_CIPHER_ID_AES;

// Operation modes
pub const GCM_ENCRYPT = c.MBEDTLS_GCM_ENCRYPT;
pub const GCM_DECRYPT = c.MBEDTLS_GCM_DECRYPT;

// ============================================================================
// AEAD - ChaCha20-Poly1305
// ============================================================================

pub const chachapoly_context = c.mbedtls_chachapoly_context;

pub const chachapoly_init = c.mbedtls_chachapoly_init;
pub const chachapoly_free = c.mbedtls_chachapoly_free;
pub const chachapoly_setkey = c.mbedtls_chachapoly_setkey;
pub const chachapoly_encrypt_and_tag = c.mbedtls_chachapoly_encrypt_and_tag;
pub const chachapoly_auth_decrypt = c.mbedtls_chachapoly_auth_decrypt;

// ============================================================================
// ECC - Elliptic Curve Diffie-Hellman
// ============================================================================

pub const ecdh_context = c.mbedtls_ecdh_context;
pub const ecp_group = c.mbedtls_ecp_group;
pub const ecp_point = c.mbedtls_ecp_point;
pub const mpi = c.mbedtls_mpi;

pub const ecdh_init = c.mbedtls_ecdh_init;
pub const ecdh_free = c.mbedtls_ecdh_free;
pub const ecdh_setup = c.mbedtls_ecdh_setup;
pub const ecdh_gen_public = c.mbedtls_ecdh_gen_public;
pub const ecdh_compute_shared = c.mbedtls_ecdh_compute_shared;
pub const ecdh_make_public = c.mbedtls_ecdh_make_public;
pub const ecdh_read_public = c.mbedtls_ecdh_read_public;
pub const ecdh_calc_secret = c.mbedtls_ecdh_calc_secret;

// ECP Group IDs
pub const ECP_DP_CURVE25519 = c.MBEDTLS_ECP_DP_CURVE25519;
pub const ECP_DP_SECP256R1 = c.MBEDTLS_ECP_DP_SECP256R1;
pub const ECP_DP_SECP384R1 = c.MBEDTLS_ECP_DP_SECP384R1;

// ECP functions
pub const ecp_group_init = c.mbedtls_ecp_group_init;
pub const ecp_group_free = c.mbedtls_ecp_group_free;
pub const ecp_group_load = c.mbedtls_ecp_group_load;
pub const ecp_point_init = c.mbedtls_ecp_point_init;
pub const ecp_point_free = c.mbedtls_ecp_point_free;
pub const ecp_point_read_binary = c.mbedtls_ecp_point_read_binary;
pub const ecp_point_write_binary = c.mbedtls_ecp_point_write_binary;
pub const ecp_mul = c.mbedtls_ecp_mul;

// ECDSA signature verification
pub const ecdsa_verify = c.mbedtls_ecdsa_verify;

// Type aliases for API compatibility
pub const mbedtls_ecp_group = c.mbedtls_ecp_group;
pub const mbedtls_ecp_point = c.mbedtls_ecp_point;
pub const mbedtls_mpi = c.mbedtls_mpi;
pub const mbedtls_ecp_group_init = c.mbedtls_ecp_group_init;
pub const mbedtls_ecp_group_free = c.mbedtls_ecp_group_free;
pub const mbedtls_ecp_group_load = c.mbedtls_ecp_group_load;
pub const mbedtls_ecp_point_init = c.mbedtls_ecp_point_init;
pub const mbedtls_ecp_point_free = c.mbedtls_ecp_point_free;
pub const mbedtls_ecp_point_read_binary = c.mbedtls_ecp_point_read_binary;
pub const mbedtls_mpi_init = c.mbedtls_mpi_init;
pub const mbedtls_mpi_free = c.mbedtls_mpi_free;
pub const mbedtls_mpi_read_binary = c.mbedtls_mpi_read_binary;
pub const mbedtls_ecdsa_verify = c.mbedtls_ecdsa_verify;
pub const MBEDTLS_ECP_DP_SECP256R1 = c.MBEDTLS_ECP_DP_SECP256R1;
pub const MBEDTLS_ECP_DP_SECP384R1 = c.MBEDTLS_ECP_DP_SECP384R1;

// MPI functions
pub const mpi_init = c.mbedtls_mpi_init;
pub const mpi_free = c.mbedtls_mpi_free;
pub const mpi_read_binary = c.mbedtls_mpi_read_binary;
pub const mpi_write_binary = c.mbedtls_mpi_write_binary;
pub const mpi_size = c.mbedtls_mpi_size;

// Point format
pub const ECP_PF_UNCOMPRESSED = c.MBEDTLS_ECP_PF_UNCOMPRESSED;
pub const ECP_PF_COMPRESSED = c.MBEDTLS_ECP_PF_COMPRESSED;

// ============================================================================
// Random Number Generator (for ECC operations)
// ============================================================================

pub const ctr_drbg_context = c.mbedtls_ctr_drbg_context;
pub const entropy_context = c.mbedtls_entropy_context;

pub const ctr_drbg_init = c.mbedtls_ctr_drbg_init;
pub const ctr_drbg_free = c.mbedtls_ctr_drbg_free;
pub const ctr_drbg_seed = c.mbedtls_ctr_drbg_seed;
pub const ctr_drbg_random = c.mbedtls_ctr_drbg_random;

pub const entropy_init = c.mbedtls_entropy_init;
pub const entropy_free = c.mbedtls_entropy_free;
pub const entropy_func = c.mbedtls_entropy_func;

// ============================================================================
// KDF - HKDF
// ============================================================================

pub const hkdf = c.mbedtls_hkdf;
pub const hkdf_extract = c.mbedtls_hkdf_extract;
pub const hkdf_expand = c.mbedtls_hkdf_expand;

// ============================================================================
// MAC - Message Digest (for HMAC)
// ============================================================================

pub const md_context_t = c.mbedtls_md_context_t;
pub const md_type_t = c.mbedtls_md_type_t;
pub const md_info_t = c.mbedtls_md_info_t;

pub const md_init = c.mbedtls_md_init;
pub const md_free = c.mbedtls_md_free;
pub const md_setup = c.mbedtls_md_setup;
pub const md_clone = c.mbedtls_md_clone;
pub const md_starts = c.mbedtls_md_starts;
pub const md_update = c.mbedtls_md_update;
pub const md_finish = c.mbedtls_md_finish;
pub const md_hmac_starts = c.mbedtls_md_hmac_starts;
pub const md_hmac_update = c.mbedtls_md_hmac_update;
pub const md_hmac_finish = c.mbedtls_md_hmac_finish;
pub const md_hmac_reset = c.mbedtls_md_hmac_reset;
pub const md_hmac = c.mbedtls_md_hmac;
pub const md_info_from_type = c.mbedtls_md_info_from_type;
pub const md_get_size = c.mbedtls_md_get_size;

// MD type constants
pub const MD_SHA256 = c.MBEDTLS_MD_SHA256;
pub const MD_SHA384 = c.MBEDTLS_MD_SHA384;
pub const MD_SHA512 = c.MBEDTLS_MD_SHA512;
pub const MD_SHA1 = c.MBEDTLS_MD_SHA1;

// ============================================================================
// X.509 Certificates
// ============================================================================

pub const x509_crt = c.mbedtls_x509_crt;
pub const x509_crl = c.mbedtls_x509_crl;
pub const x509_name = c.mbedtls_x509_name;
pub const x509_time = c.mbedtls_x509_time;

pub const x509_crt_init = c.mbedtls_x509_crt_init;
pub const x509_crt_free = c.mbedtls_x509_crt_free;
pub const x509_crt_parse = c.mbedtls_x509_crt_parse;
pub const x509_crt_parse_der = c.mbedtls_x509_crt_parse_der;
pub const x509_crt_verify = c.mbedtls_x509_crt_verify;
pub const x509_crt_verify_with_profile = c.mbedtls_x509_crt_verify_with_profile;

pub const x509_crl_init = c.mbedtls_x509_crl_init;
pub const x509_crl_free = c.mbedtls_x509_crl_free;

// ============================================================================
// Error codes
// ============================================================================

pub const ERR_GCM_AUTH_FAILED = c.MBEDTLS_ERR_GCM_AUTH_FAILED;
pub const ERR_CHACHAPOLY_AUTH_FAILED = c.MBEDTLS_ERR_CHACHAPOLY_AUTH_FAILED;

// ============================================================================
// Sub-modules (C helper wrappers)
// These use _helper suffix to avoid conflict with raw C API exports above
// ============================================================================

pub const x25519_helper = @import("mbed_tls/x25519.zig");
pub const p256_helper = @import("mbed_tls/p256.zig");
pub const p384_helper = @import("mbed_tls/p384.zig");
pub const aes_gcm_helper = @import("mbed_tls/aes_gcm.zig");
pub const chachapoly_helper = @import("mbed_tls/chachapoly.zig");
pub const hkdf_helper = @import("mbed_tls/hkdf.zig");
pub const rsa_helper = @import("mbed_tls/rsa.zig");
pub const cert_helper = @import("mbed_tls/cert.zig");
