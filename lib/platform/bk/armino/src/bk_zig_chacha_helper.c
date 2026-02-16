/**
 * bk_zig_chacha_helper.c — ChaCha20-Poly1305 AEAD via mbedTLS
 *
 * Simple byte-array interface for Zig FFI.
 * Returns 0 on success, non-zero on error.
 */

#include <mbedtls/chachapoly.h>

int bk_zig_chacha20poly1305_encrypt(
    const unsigned char key[32],
    const unsigned char nonce[12],
    const unsigned char *aad, unsigned int aad_len,
    const unsigned char *input, unsigned int input_len,
    unsigned char *output,
    unsigned char tag[16])
{
    mbedtls_chachapoly_context ctx;
    mbedtls_chachapoly_init(&ctx);

    int ret = mbedtls_chachapoly_setkey(&ctx, key);
    if (ret != 0) { mbedtls_chachapoly_free(&ctx); return ret; }

    ret = mbedtls_chachapoly_encrypt_and_tag(&ctx,
        input_len, nonce, aad, aad_len, input, output, tag);

    mbedtls_chachapoly_free(&ctx);
    return ret;
}

int bk_zig_chacha20poly1305_decrypt(
    const unsigned char key[32],
    const unsigned char nonce[12],
    const unsigned char *aad, unsigned int aad_len,
    const unsigned char *input, unsigned int input_len,
    unsigned char *output,
    const unsigned char tag[16])
{
    mbedtls_chachapoly_context ctx;
    mbedtls_chachapoly_init(&ctx);

    int ret = mbedtls_chachapoly_setkey(&ctx, key);
    if (ret != 0) { mbedtls_chachapoly_free(&ctx); return ret; }

    ret = mbedtls_chachapoly_auth_decrypt(&ctx,
        input_len, nonce, aad, aad_len, tag, input, output);

    mbedtls_chachapoly_free(&ctx);
    return ret;
}
