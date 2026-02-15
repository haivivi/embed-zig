/**
 * ChaCha20-Poly1305 Helper for mbedTLS
 *
 * C helper to provide ChaCha20-Poly1305 AEAD using mbedTLS.
 * Required because Zig's @cImport cannot handle opaque mbedTLS structs.
 */

#ifndef CHACHAPOLY_HELPER_H
#define CHACHAPOLY_HELPER_H

#include <stdint.h>
#include <stddef.h>

/**
 * ChaCha20-Poly1305 encrypt and authenticate
 *
 * @param key        256-bit key (32 bytes)
 * @param nonce      96-bit nonce (12 bytes)
 * @param aad        Additional authenticated data (can be NULL if aad_len==0)
 * @param aad_len    AAD length in bytes
 * @param input      Plaintext to encrypt
 * @param input_len  Input length in bytes
 * @param output     Output buffer for ciphertext (same size as input)
 * @param tag        Output buffer for authentication tag (16 bytes)
 * @return           0 on success, non-zero on error
 */
int chachapoly_encrypt(
    const uint8_t key[32],
    const uint8_t nonce[12],
    const uint8_t *aad, size_t aad_len,
    const uint8_t *input, size_t input_len,
    uint8_t *output,
    uint8_t tag[16]);

/**
 * ChaCha20-Poly1305 decrypt and verify
 *
 * @param key        256-bit key (32 bytes)
 * @param nonce      96-bit nonce (12 bytes)
 * @param aad        Additional authenticated data (can be NULL if aad_len==0)
 * @param aad_len    AAD length in bytes
 * @param input      Ciphertext to decrypt
 * @param input_len  Input length in bytes
 * @param output     Output buffer for plaintext (same size as input)
 * @param tag        Authentication tag to verify (16 bytes)
 * @return           0 on success, MBEDTLS_ERR_CHACHAPOLY_AUTH_FAILED on tag mismatch
 */
int chachapoly_decrypt(
    const uint8_t key[32],
    const uint8_t nonce[12],
    const uint8_t *aad, size_t aad_len,
    const uint8_t *input, size_t input_len,
    uint8_t *output,
    const uint8_t tag[16]);

#endif /* CHACHAPOLY_HELPER_H */
