/**
 * bk_zig_rsa_helper.c — RSA signature verification via mbedTLS
 *
 * Same logic as ESP's rsa_helper.c, adapted for Armino.
 * Supports PKCS#1 v1.5 and RSA-PSS with SHA-256/384/512.
 */

#include <string.h>
#include <mbedtls/rsa.h>
#include <mbedtls/md.h>
#include <mbedtls/bignum.h>

static mbedtls_md_type_t hash_id_to_md_type(int hash_id) {
    switch (hash_id) {
        case 0: return MBEDTLS_MD_SHA256;
        case 1: return MBEDTLS_MD_SHA384;
        case 2: return MBEDTLS_MD_SHA512;
        default: return MBEDTLS_MD_NONE;
    }
}

static int rsa_init_public_key(
    mbedtls_rsa_context *ctx,
    const unsigned char *modulus, unsigned int modulus_len,
    const unsigned char *exponent, unsigned int exponent_len)
{
    mbedtls_mpi N, E;
    mbedtls_rsa_init(ctx);
    mbedtls_mpi_init(&N);
    mbedtls_mpi_init(&E);

    int ret = mbedtls_mpi_read_binary(&N, modulus, modulus_len);
    if (ret != 0) goto cleanup;
    ret = mbedtls_mpi_read_binary(&E, exponent, exponent_len);
    if (ret != 0) goto cleanup;
    ret = mbedtls_rsa_import(ctx, &N, NULL, NULL, NULL, &E);
    if (ret != 0) goto cleanup;
    ret = mbedtls_rsa_complete(ctx);

cleanup:
    mbedtls_mpi_free(&N);
    mbedtls_mpi_free(&E);
    return ret;
}

int bk_zig_rsa_pkcs1v15_verify(
    const unsigned char *modulus, unsigned int modulus_len,
    const unsigned char *exponent, unsigned int exponent_len,
    const unsigned char *hash, unsigned int hash_len,
    const unsigned char *signature,
    int hash_id)
{
    if (!modulus || !exponent || !hash || !signature) return -1;
    mbedtls_md_type_t md_type = hash_id_to_md_type(hash_id);
    if (md_type == MBEDTLS_MD_NONE) return -1;

    mbedtls_rsa_context ctx;
    int ret = rsa_init_public_key(&ctx, modulus, modulus_len, exponent, exponent_len);
    if (ret != 0) { mbedtls_rsa_free(&ctx); return ret; }

    mbedtls_rsa_set_padding(&ctx, MBEDTLS_RSA_PKCS_V15, MBEDTLS_MD_NONE);
    ret = mbedtls_rsa_pkcs1_verify(&ctx, md_type, hash_len, hash, signature);

    mbedtls_rsa_free(&ctx);
    return ret;
}

int bk_zig_rsa_pss_verify(
    const unsigned char *modulus, unsigned int modulus_len,
    const unsigned char *exponent, unsigned int exponent_len,
    const unsigned char *hash, unsigned int hash_len,
    const unsigned char *signature,
    int hash_id)
{
    if (!modulus || !exponent || !hash || !signature) return -1;
    mbedtls_md_type_t md_type = hash_id_to_md_type(hash_id);
    if (md_type == MBEDTLS_MD_NONE) return -1;

    mbedtls_rsa_context ctx;
    int ret = rsa_init_public_key(&ctx, modulus, modulus_len, exponent, exponent_len);
    if (ret != 0) { mbedtls_rsa_free(&ctx); return ret; }

    mbedtls_rsa_set_padding(&ctx, MBEDTLS_RSA_PKCS_V21, md_type);
    ret = mbedtls_rsa_rsassa_pss_verify_ext(
        &ctx, md_type, hash_len, hash,
        md_type, MBEDTLS_RSA_SALT_LEN_ANY, signature);

    mbedtls_rsa_free(&ctx);
    return ret;
}
