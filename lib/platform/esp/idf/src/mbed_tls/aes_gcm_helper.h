/**
 * AES-GCM Helper for mbedTLS
 * 
 * C helper to provide AES-GCM encryption/decryption using mbedTLS.
 * Required because Zig's @cImport cannot handle opaque mbedTLS structs.
 */

#ifndef AES_GCM_HELPER_H
#define AES_GCM_HELPER_H

#include <stdint.h>
#include <stddef.h>

/**
 * AES-GCM encrypt and authenticate
 * 
 * @param key        AES key (16/24/32 bytes for AES-128/192/256)
 * @param key_len    Key length in bytes
 * @param iv         Initialization vector (typically 12 bytes)
 * @param iv_len     IV length in bytes
 * @param aad        Additional authenticated data (can be NULL)
 * @param aad_len    AAD length in bytes
 * @param input      Plaintext to encrypt
 * @param input_len  Input length in bytes
 * @param output     Output buffer for ciphertext (same size as input)
 * @param tag        Output buffer for authentication tag (16 bytes)
 * @return           0 on success, non-zero on error
 */
int aes_gcm_encrypt(
    const uint8_t *key, size_t key_len,
    const uint8_t *iv, size_t iv_len,
    const uint8_t *aad, size_t aad_len,
    const uint8_t *input, size_t input_len,
    uint8_t *output,
    uint8_t tag[16]);

/**
 * AES-GCM decrypt and verify
 * 
 * @param key        AES key (16/24/32 bytes for AES-128/192/256)
 * @param key_len    Key length in bytes
 * @param iv         Initialization vector (typically 12 bytes)
 * @param iv_len     IV length in bytes
 * @param aad        Additional authenticated data (can be NULL)
 * @param aad_len    AAD length in bytes
 * @param input      Ciphertext to decrypt
 * @param input_len  Input length in bytes
 * @param output     Output buffer for plaintext (same size as input)
 * @param tag        Authentication tag to verify (16 bytes)
 * @return           0 on success, MBEDTLS_ERR_GCM_AUTH_FAILED on tag mismatch
 */
int aes_gcm_decrypt(
    const uint8_t *key, size_t key_len,
    const uint8_t *iv, size_t iv_len,
    const uint8_t *aad, size_t aad_len,
    const uint8_t *input, size_t input_len,
    uint8_t *output,
    const uint8_t tag[16]);

#endif /* AES_GCM_HELPER_H */
