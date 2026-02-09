/**
 * bk_zig_crypto_helper.c — Crypto primitives for Zig via mbedTLS
 *
 * Wraps mbedTLS with simple byte-array interfaces for Zig FFI.
 * All functions return 0 on success, non-zero on error.
 */

#include <string.h>
#include <mbedtls/sha256.h>
#include <mbedtls/sha512.h>
#include <mbedtls/sha1.h>
#include <mbedtls/gcm.h>
#include <mbedtls/hkdf.h>
#include <mbedtls/md.h>
#include <mbedtls/ecp.h>
#include <mbedtls/ecdh.h>
#include <mbedtls/bignum.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>

/* ========================================================================
 * RNG — uses bk_rand() hardware RNG
 * ======================================================================== */

extern int bk_rand(void);

void bk_zig_rng_fill(unsigned char *buf, unsigned int len) {
    unsigned int i = 0;
    while (i + 4 <= len) {
        int r = bk_rand();
        memcpy(buf + i, &r, 4);
        i += 4;
    }
    if (i < len) {
        int r = bk_rand();
        memcpy(buf + i, &r, len - i);
    }
}

/* mbedTLS RNG callback using bk_rand */
static int bk_rng_callback(void *ctx, unsigned char *output, size_t len) {
    (void)ctx;
    bk_zig_rng_fill(output, (unsigned int)len);
    return 0;
}

/* ========================================================================
 * SHA-256
 * ======================================================================== */

int bk_zig_sha256(const unsigned char *input, unsigned int len,
                   unsigned char output[32]) {
    return mbedtls_sha256(input, len, output, 0); /* 0 = SHA-256 */
}

/* ========================================================================
 * SHA-384 / SHA-512
 * ======================================================================== */

int bk_zig_sha384(const unsigned char *input, unsigned int len,
                   unsigned char output[48]) {
    unsigned char full[64];
    int ret = mbedtls_sha512(input, len, full, 1); /* 1 = SHA-384 */
    if (ret == 0) memcpy(output, full, 48);
    return ret;
}

int bk_zig_sha512(const unsigned char *input, unsigned int len,
                   unsigned char output[64]) {
    return mbedtls_sha512(input, len, output, 0); /* 0 = SHA-512 */
}

/* ========================================================================
 * SHA-1 (legacy, for TLS 1.2)
 * ======================================================================== */

int bk_zig_sha1(const unsigned char *input, unsigned int len,
                  unsigned char output[20]) {
    return mbedtls_sha1(input, len, output);
}

/* ========================================================================
 * AES-GCM
 * ======================================================================== */

int bk_zig_aes_gcm_encrypt(
    const unsigned char *key, unsigned int key_len,
    const unsigned char *iv, unsigned int iv_len,
    const unsigned char *aad, unsigned int aad_len,
    const unsigned char *input, unsigned int input_len,
    unsigned char *output,
    unsigned char tag[16])
{
    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    int ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, key_len * 8);
    if (ret != 0) { mbedtls_gcm_free(&gcm); return ret; }
    ret = mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT,
                                     input_len, iv, iv_len,
                                     aad, aad_len,
                                     input, output, 16, tag);
    mbedtls_gcm_free(&gcm);
    return ret;
}

int bk_zig_aes_gcm_decrypt(
    const unsigned char *key, unsigned int key_len,
    const unsigned char *iv, unsigned int iv_len,
    const unsigned char *aad, unsigned int aad_len,
    const unsigned char *input, unsigned int input_len,
    unsigned char *output,
    const unsigned char tag[16])
{
    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    int ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, key_len * 8);
    if (ret != 0) { mbedtls_gcm_free(&gcm); return ret; }
    ret = mbedtls_gcm_auth_decrypt(&gcm, input_len,
                                    iv, iv_len,
                                    aad, aad_len,
                                    tag, 16,
                                    input, output);
    mbedtls_gcm_free(&gcm);
    return ret;
}

/* ========================================================================
 * HKDF (Extract + Expand)
 * ======================================================================== */

int bk_zig_hkdf_extract(
    const unsigned char *salt, unsigned int salt_len,
    const unsigned char *ikm, unsigned int ikm_len,
    unsigned char *prk, unsigned int hash_len)
{
    const mbedtls_md_info_t *md;
    if (hash_len == 32) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    else if (hash_len == 48) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA384);
    else if (hash_len == 64) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA512);
    else return -1;
    return mbedtls_hkdf_extract(md, salt, salt_len, ikm, ikm_len, prk);
}

int bk_zig_hkdf_expand(
    const unsigned char *prk, unsigned int prk_len,
    const unsigned char *info, unsigned int info_len,
    unsigned char *okm, unsigned int okm_len)
{
    const mbedtls_md_info_t *md;
    if (prk_len == 32) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    else if (prk_len == 48) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA384);
    else if (prk_len == 64) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA512);
    else return -1;
    return mbedtls_hkdf_expand(md, prk, prk_len, info, info_len, okm, okm_len);
}

/* ========================================================================
 * HMAC
 * ======================================================================== */

int bk_zig_hmac(
    unsigned int hash_len,
    const unsigned char *key, unsigned int key_len,
    const unsigned char *input, unsigned int input_len,
    unsigned char *output)
{
    const mbedtls_md_info_t *md;
    if (hash_len == 32) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    else if (hash_len == 48) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA384);
    else if (hash_len == 64) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA512);
    else return -1;
    return mbedtls_md_hmac(md, key, key_len, input, input_len, output);
}

/* ========================================================================
 * P-256 (secp256r1) ECDH
 * ======================================================================== */

int bk_zig_p256_keypair(
    const unsigned char seed[32],
    unsigned char sk_out[32],
    unsigned char pk_out[65])
{
    mbedtls_ecp_group grp;
    mbedtls_mpi d;
    mbedtls_ecp_point Q;

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&Q);

    int ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) goto cleanup;

    /* Use seed as secret key (clamp to group order) */
    ret = mbedtls_mpi_read_binary(&d, seed, 32);
    if (ret != 0) goto cleanup;
    ret = mbedtls_mpi_mod_mpi(&d, &d, &grp.N);
    if (ret != 0) goto cleanup;

    /* Compute public key Q = d * G */
    ret = mbedtls_ecp_mul(&grp, &Q, &d, &grp.G, bk_rng_callback, NULL);
    if (ret != 0) goto cleanup;

    /* Export */
    ret = mbedtls_mpi_write_binary(&d, sk_out, 32);
    if (ret != 0) goto cleanup;

    size_t olen;
    ret = mbedtls_ecp_point_write_binary(&grp, &Q,
                                          MBEDTLS_ECP_PF_UNCOMPRESSED,
                                          &olen, pk_out, 65);

cleanup:
    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return ret;
}

int bk_zig_p256_ecdh(
    const unsigned char sk[32],
    const unsigned char pk[65],
    unsigned char out[32])
{
    mbedtls_ecp_group grp;
    mbedtls_mpi d, z;
    mbedtls_ecp_point Q;

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_mpi_init(&z);
    mbedtls_ecp_point_init(&Q);

    int ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) goto cleanup;

    ret = mbedtls_mpi_read_binary(&d, sk, 32);
    if (ret != 0) goto cleanup;

    ret = mbedtls_ecp_point_read_binary(&grp, &Q, pk, 65);
    if (ret != 0) goto cleanup;

    /* Compute shared secret: z = d * Q (x-coordinate) */
    ret = mbedtls_ecdh_compute_shared(&grp, &z, &Q, &d, bk_rng_callback, NULL);
    if (ret != 0) goto cleanup;

    ret = mbedtls_mpi_write_binary(&z, out, 32);

cleanup:
    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&z);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return ret;
}

int bk_zig_p256_compute_public(
    const unsigned char sk[32],
    unsigned char pk_out[65])
{
    mbedtls_ecp_group grp;
    mbedtls_mpi d;
    mbedtls_ecp_point Q;

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&Q);

    int ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) goto cleanup;

    ret = mbedtls_mpi_read_binary(&d, sk, 32);
    if (ret != 0) goto cleanup;

    ret = mbedtls_ecp_mul(&grp, &Q, &d, &grp.G, bk_rng_callback, NULL);
    if (ret != 0) goto cleanup;

    size_t olen;
    ret = mbedtls_ecp_point_write_binary(&grp, &Q,
                                          MBEDTLS_ECP_PF_UNCOMPRESSED,
                                          &olen, pk_out, 65);

cleanup:
    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return ret;
}

/* ========================================================================
 * P-384 (secp384r1) ECDH
 * ======================================================================== */

int bk_zig_p384_keypair(
    const unsigned char seed[48],
    unsigned char sk_out[48],
    unsigned char pk_out[97])
{
    mbedtls_ecp_group grp;
    mbedtls_mpi d;
    mbedtls_ecp_point Q;

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&Q);

    int ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP384R1);
    if (ret != 0) goto cleanup;

    ret = mbedtls_mpi_read_binary(&d, seed, 48);
    if (ret != 0) goto cleanup;
    ret = mbedtls_mpi_mod_mpi(&d, &d, &grp.N);
    if (ret != 0) goto cleanup;

    ret = mbedtls_ecp_mul(&grp, &Q, &d, &grp.G, bk_rng_callback, NULL);
    if (ret != 0) goto cleanup;

    ret = mbedtls_mpi_write_binary(&d, sk_out, 48);
    if (ret != 0) goto cleanup;

    size_t olen;
    ret = mbedtls_ecp_point_write_binary(&grp, &Q,
                                          MBEDTLS_ECP_PF_UNCOMPRESSED,
                                          &olen, pk_out, 97);

cleanup:
    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return ret;
}

int bk_zig_p384_ecdh(
    const unsigned char sk[48],
    const unsigned char pk[97],
    unsigned char out[48])
{
    mbedtls_ecp_group grp;
    mbedtls_mpi d, z;
    mbedtls_ecp_point Q;

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_mpi_init(&z);
    mbedtls_ecp_point_init(&Q);

    int ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP384R1);
    if (ret != 0) goto cleanup;

    ret = mbedtls_mpi_read_binary(&d, sk, 48);
    if (ret != 0) goto cleanup;

    ret = mbedtls_ecp_point_read_binary(&grp, &Q, pk, 97);
    if (ret != 0) goto cleanup;

    ret = mbedtls_ecdh_compute_shared(&grp, &z, &Q, &d, bk_rng_callback, NULL);
    if (ret != 0) goto cleanup;

    ret = mbedtls_mpi_write_binary(&z, out, 48);

cleanup:
    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&z);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return ret;
}

/* ========================================================================
 * ECDSA P-256 Verify
 * ======================================================================== */

int bk_zig_ecdsa_p256_verify(
    const unsigned char hash[32],
    const unsigned char r[32],
    const unsigned char s[32],
    const unsigned char pk[65])
{
    mbedtls_ecp_group grp;
    mbedtls_ecp_point Q;
    mbedtls_mpi r_mpi, s_mpi;

    mbedtls_ecp_group_init(&grp);
    mbedtls_ecp_point_init(&Q);
    mbedtls_mpi_init(&r_mpi);
    mbedtls_mpi_init(&s_mpi);

    int ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) goto cleanup;

    ret = mbedtls_ecp_point_read_binary(&grp, &Q, pk, 65);
    if (ret != 0) goto cleanup;

    ret = mbedtls_mpi_read_binary(&r_mpi, r, 32);
    if (ret != 0) goto cleanup;
    ret = mbedtls_mpi_read_binary(&s_mpi, s, 32);
    if (ret != 0) goto cleanup;

    ret = mbedtls_ecdsa_verify(&grp, hash, 32, &Q, &r_mpi, &s_mpi);

cleanup:
    mbedtls_mpi_free(&s_mpi);
    mbedtls_mpi_free(&r_mpi);
    mbedtls_ecp_point_free(&Q);
    mbedtls_ecp_group_free(&grp);
    return ret;
}

/* ========================================================================
 * ECDSA P-384 Verify
 * ======================================================================== */

int bk_zig_ecdsa_p384_verify(
    const unsigned char hash[48],
    const unsigned char r[48],
    const unsigned char s[48],
    const unsigned char pk[97])
{
    mbedtls_ecp_group grp;
    mbedtls_ecp_point Q;
    mbedtls_mpi r_mpi, s_mpi;

    mbedtls_ecp_group_init(&grp);
    mbedtls_ecp_point_init(&Q);
    mbedtls_mpi_init(&r_mpi);
    mbedtls_mpi_init(&s_mpi);

    int ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP384R1);
    if (ret != 0) goto cleanup;

    ret = mbedtls_ecp_point_read_binary(&grp, &Q, pk, 97);
    if (ret != 0) goto cleanup;

    ret = mbedtls_mpi_read_binary(&r_mpi, r, 48);
    if (ret != 0) goto cleanup;
    ret = mbedtls_mpi_read_binary(&s_mpi, s, 48);
    if (ret != 0) goto cleanup;

    ret = mbedtls_ecdsa_verify(&grp, hash, 48, &Q, &r_mpi, &s_mpi);

cleanup:
    mbedtls_mpi_free(&s_mpi);
    mbedtls_mpi_free(&r_mpi);
    mbedtls_ecp_point_free(&Q);
    mbedtls_ecp_group_free(&grp);
    return ret;
}
