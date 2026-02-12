/**
 * @file rsa_helper.c
 * @brief RSA signature verification helper implementation using mbedTLS
 *
 * Wraps mbedTLS RSA verification functions to provide simple byte-array
 * interfaces for Zig integration.
 *
 * Uses mbedTLS RSA verification APIs:
 * - mbedtls_rsa_pkcs1_verify: PKCS#1 v1.5 signature verification
 * - mbedtls_rsa_rsassa_pss_verify_ext: RSA-PSS signature verification
 *
 * Supports SHA-256, SHA-384, and SHA-512 hash algorithms.
 */

#include "rsa_helper.h"

#include <string.h>
#include <mbedtls/rsa.h>
#include <mbedtls/md.h>
#include <mbedtls/bignum.h>

/**
 * Map hash_id to mbedTLS message digest type
 */
static mbedtls_md_type_t hash_id_to_md_type(int hash_id)
{
    switch (hash_id) {
        case 0: return MBEDTLS_MD_SHA256;
        case 1: return MBEDTLS_MD_SHA384;
        case 2: return MBEDTLS_MD_SHA512;
        default: return MBEDTLS_MD_NONE;
    }
}

/**
 * Initialize RSA context with public key components
 */
static int rsa_init_public_key(
    mbedtls_rsa_context *ctx,
    const uint8_t *modulus,
    size_t modulus_len,
    const uint8_t *exponent,
    size_t exponent_len
) {
    int ret;
    mbedtls_mpi N, E;

    mbedtls_rsa_init(ctx);
    mbedtls_mpi_init(&N);
    mbedtls_mpi_init(&E);

    /* Load modulus (n) */
    ret = mbedtls_mpi_read_binary(&N, modulus, modulus_len);
    if (ret != 0) {
        goto cleanup;
    }

    /* Load exponent (e) */
    ret = mbedtls_mpi_read_binary(&E, exponent, exponent_len);
    if (ret != 0) {
        goto cleanup;
    }

    /* Import public key into RSA context */
    ret = mbedtls_rsa_import(ctx, &N, NULL, NULL, NULL, &E);
    if (ret != 0) {
        goto cleanup;
    }

    /* Complete the RSA context setup */
    ret = mbedtls_rsa_complete(ctx);

cleanup:
    mbedtls_mpi_free(&N);
    mbedtls_mpi_free(&E);
    return ret;
}

/**
 * Verify RSA PKCS#1 v1.5 signature
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
) {
    int ret;
    mbedtls_rsa_context ctx;
    mbedtls_md_type_t md_type;

    /* Validate inputs */
    if (!modulus || !exponent || !hash || !signature) {
        return -1;
    }

    md_type = hash_id_to_md_type(hash_id);
    if (md_type == MBEDTLS_MD_NONE) {
        return -1;
    }

    /* Initialize RSA context with public key */
    ret = rsa_init_public_key(&ctx, modulus, modulus_len, exponent, exponent_len);
    if (ret != 0) {
        mbedtls_rsa_free(&ctx);
        return ret;
    }

    /* Set padding mode to PKCS#1 v1.5 */
    mbedtls_rsa_set_padding(&ctx, MBEDTLS_RSA_PKCS_V15, MBEDTLS_MD_NONE);

    /* Verify signature */
    ret = mbedtls_rsa_pkcs1_verify(
        &ctx,
        md_type,
        (unsigned int)hash_len,
        hash,
        signature
    );

    mbedtls_rsa_free(&ctx);
    return ret;
}

/**
 * Verify RSA-PSS signature
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
) {
    int ret;
    mbedtls_rsa_context ctx;
    mbedtls_md_type_t md_type;

    /* Validate inputs */
    if (!modulus || !exponent || !hash || !signature) {
        return -1;
    }

    md_type = hash_id_to_md_type(hash_id);
    if (md_type == MBEDTLS_MD_NONE) {
        return -1;
    }

    /* Initialize RSA context with public key */
    ret = rsa_init_public_key(&ctx, modulus, modulus_len, exponent, exponent_len);
    if (ret != 0) {
        mbedtls_rsa_free(&ctx);
        return ret;
    }

    /* Set padding mode to PSS */
    mbedtls_rsa_set_padding(&ctx, MBEDTLS_RSA_PKCS_V21, md_type);

    /* Verify signature using PSS with automatic salt length detection */
    ret = mbedtls_rsa_rsassa_pss_verify_ext(
        &ctx,
        md_type,
        (unsigned int)hash_len,
        hash,
        md_type,
        MBEDTLS_RSA_SALT_LEN_ANY,  /* Auto-detect salt length */
        signature
    );

    mbedtls_rsa_free(&ctx);
    return ret;
}
