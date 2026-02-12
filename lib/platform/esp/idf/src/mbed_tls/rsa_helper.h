/**
 * @file rsa_helper.h
 * @brief RSA signature verification helper for Zig integration
 *
 * This C helper wraps mbedTLS RSA signature verification operations because:
 * - mbedTLS 3.x uses opaque structures for RSA contexts
 * - Zig's @cImport can't handle these opaque types
 *
 * We expose simple byte-array interfaces that Zig can easily call.
 */

#ifndef RSA_HELPER_H
#define RSA_HELPER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Verify RSA PKCS#1 v1.5 signature
 *
 * Verifies a signature using RSA PKCS#1 v1.5 padding scheme.
 *
 * @param modulus       RSA modulus (n) in big-endian format
 * @param modulus_len   Length of modulus in bytes (256 for 2048-bit, 512 for 4096-bit)
 * @param exponent      RSA public exponent (e) in big-endian format
 * @param exponent_len  Length of exponent in bytes
 * @param hash          Message digest to verify
 * @param hash_len      Length of hash in bytes (32 for SHA-256, 48 for SHA-384, 64 for SHA-512)
 * @param signature     Signature to verify (same length as modulus)
 * @param hash_id       Hash algorithm ID (0=SHA256, 1=SHA384, 2=SHA512)
 * @return 0 on success (signature valid), non-zero on error or invalid signature
 */
int rsa_pkcs1v15_verify(
    const uint8_t *modulus,
    size_t modulus_len,
    const uint8_t *exponent,
    size_t exponent_len,
    const uint8_t *hash,
    size_t hash_len,
    const uint8_t *signature,
    int hash_id
);

/**
 * @brief Verify RSA-PSS signature
 *
 * Verifies a signature using RSA-PSS padding scheme.
 *
 * @param modulus       RSA modulus (n) in big-endian format
 * @param modulus_len   Length of modulus in bytes (256 for 2048-bit, 512 for 4096-bit)
 * @param exponent      RSA public exponent (e) in big-endian format
 * @param exponent_len  Length of exponent in bytes
 * @param hash          Message digest to verify
 * @param hash_len      Length of hash in bytes (32 for SHA-256, 48 for SHA-384, 64 for SHA-512)
 * @param signature     Signature to verify (same length as modulus)
 * @param hash_id       Hash algorithm ID (0=SHA256, 1=SHA384, 2=SHA512)
 * @return 0 on success (signature valid), non-zero on error or invalid signature
 */
int rsa_pss_verify(
    const uint8_t *modulus,
    size_t modulus_len,
    const uint8_t *exponent,
    size_t exponent_len,
    const uint8_t *hash,
    size_t hash_len,
    const uint8_t *signature,
    int hash_id
);

#ifdef __cplusplus
}
#endif

#endif /* RSA_HELPER_H */
