/**
 * ChaCha20-Poly1305 Helper Implementation
 *
 * Uses mbedTLS chachapoly module (software implementation).
 */

#include "chachapoly_helper.h"
#include <string.h>
#include <mbedtls/chachapoly.h>

int chachapoly_encrypt(
    const uint8_t key[32],
    const uint8_t nonce[12],
    const uint8_t *aad, size_t aad_len,
    const uint8_t *input, size_t input_len,
    uint8_t *output,
    uint8_t tag[16])
{
    mbedtls_chachapoly_context ctx;
    int ret;

    mbedtls_chachapoly_init(&ctx);

    ret = mbedtls_chachapoly_setkey(&ctx, key);
    if (ret != 0) {
        mbedtls_chachapoly_free(&ctx);
        return ret;
    }

    ret = mbedtls_chachapoly_encrypt_and_tag(&ctx,
                                              input_len,
                                              nonce,
                                              aad, aad_len,
                                              input, output,
                                              tag);

    mbedtls_chachapoly_free(&ctx);
    return ret;
}

int chachapoly_decrypt(
    const uint8_t key[32],
    const uint8_t nonce[12],
    const uint8_t *aad, size_t aad_len,
    const uint8_t *input, size_t input_len,
    uint8_t *output,
    const uint8_t tag[16])
{
    mbedtls_chachapoly_context ctx;
    int ret;

    mbedtls_chachapoly_init(&ctx);

    ret = mbedtls_chachapoly_setkey(&ctx, key);
    if (ret != 0) {
        mbedtls_chachapoly_free(&ctx);
        return ret;
    }

    ret = mbedtls_chachapoly_auth_decrypt(&ctx,
                                           input_len,
                                           nonce,
                                           aad, aad_len,
                                           tag,
                                           input, output);

    mbedtls_chachapoly_free(&ctx);
    return ret;
}
