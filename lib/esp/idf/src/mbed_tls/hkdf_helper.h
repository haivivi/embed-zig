/**
 * HKDF Helper for mbedTLS
 * 
 * C helper to provide HKDF (HMAC-based Key Derivation Function) using mbedTLS.
 * Required because the mbedTLS HKDF module may not be enabled in some configs.
 */

#ifndef HKDF_HELPER_H
#define HKDF_HELPER_H

#include <stdint.h>
#include <stddef.h>

/**
 * HKDF-Extract
 * 
 * @param salt       Salt value (can be NULL)
 * @param salt_len   Salt length in bytes
 * @param ikm        Input keying material
 * @param ikm_len    IKM length in bytes
 * @param prk        Output pseudorandom key (32 bytes for SHA-256, 48 for SHA-384)
 * @param hash_len   Hash output length (32 for SHA-256, 48 for SHA-384)
 * @return           0 on success, non-zero on error
 */
int hkdf_extract(
    const uint8_t *salt, size_t salt_len,
    const uint8_t *ikm, size_t ikm_len,
    uint8_t *prk, size_t hash_len);

/**
 * HKDF-Expand
 * 
 * @param prk        Pseudorandom key from Extract
 * @param prk_len    PRK length in bytes (32 for SHA-256, 48 for SHA-384)
 * @param info       Context/application info (can be NULL)
 * @param info_len   Info length in bytes
 * @param okm        Output keying material
 * @param okm_len    Desired output length in bytes
 * @return           0 on success, non-zero on error
 */
int hkdf_expand(
    const uint8_t *prk, size_t prk_len,
    const uint8_t *info, size_t info_len,
    uint8_t *okm, size_t okm_len);

#endif /* HKDF_HELPER_H */
