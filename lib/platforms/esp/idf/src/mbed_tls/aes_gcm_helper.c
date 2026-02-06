/**
 * AES-GCM Helper Implementation
 * 
 * Uses mbedTLS GCM module directly (hardware accelerated on ESP32).
 */

#include "aes_gcm_helper.h"
#include <string.h>
#include <mbedtls/gcm.h>

int aes_gcm_encrypt(
    const uint8_t *key, size_t key_len,
    const uint8_t *iv, size_t iv_len,
    const uint8_t *aad, size_t aad_len,
    const uint8_t *input, size_t input_len,
    uint8_t *output,
    uint8_t tag[16])
{
    mbedtls_gcm_context gcm;
    int ret;
    
    mbedtls_gcm_init(&gcm);
    
    ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, key_len * 8);
    if (ret != 0) {
        mbedtls_gcm_free(&gcm);
        return ret;
    }
    
    ret = mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT,
                                     input_len,
                                     iv, iv_len,
                                     aad, aad_len,
                                     input, output,
                                     16, tag);
    
    mbedtls_gcm_free(&gcm);
    return ret;
}

int aes_gcm_decrypt(
    const uint8_t *key, size_t key_len,
    const uint8_t *iv, size_t iv_len,
    const uint8_t *aad, size_t aad_len,
    const uint8_t *input, size_t input_len,
    uint8_t *output,
    const uint8_t tag[16])
{
    mbedtls_gcm_context gcm;
    int ret;
    
    mbedtls_gcm_init(&gcm);
    
    ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, key_len * 8);
    if (ret != 0) {
        mbedtls_gcm_free(&gcm);
        return ret;
    }
    
    ret = mbedtls_gcm_auth_decrypt(&gcm, input_len,
                                    iv, iv_len,
                                    aad, aad_len,
                                    tag, 16,
                                    input, output);
    
    mbedtls_gcm_free(&gcm);
    return ret;
}
