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
/* hkdf.h not used — HKDF implemented via HMAC directly */
#include <mbedtls/md.h>
#include <mbedtls/ecp.h>
#include <mbedtls/ecdh.h>
#include <mbedtls/bignum.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ecdsa.h>

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
 * SHA one-shot
 * ======================================================================== */

int bk_zig_sha256(const unsigned char *input, unsigned int len,
                   unsigned char output[32]) {
    return mbedtls_sha256(input, len, output, 0);
}

int bk_zig_sha384(const unsigned char *input, unsigned int len,
                   unsigned char output[48]) {
    unsigned char full[64];
    int ret = mbedtls_sha512(input, len, full, 1);
    if (ret == 0) memcpy(output, full, 48);
    return ret;
}

int bk_zig_sha512(const unsigned char *input, unsigned int len,
                   unsigned char output[64]) {
    return mbedtls_sha512(input, len, output, 0);
}

int bk_zig_sha1(const unsigned char *input, unsigned int len,
                  unsigned char output[20]) {
    return mbedtls_sha1(input, len, output);
}

/* ========================================================================
 * SHA streaming (init/update/final with context handles)
 * ======================================================================== */

#define MAX_SHA_CONTEXTS 4

static mbedtls_sha256_context s_sha256_ctx[MAX_SHA_CONTEXTS];
static int s_sha256_used[MAX_SHA_CONTEXTS] = {0};
static mbedtls_sha512_context s_sha512_ctx[MAX_SHA_CONTEXTS];
static int s_sha512_used[MAX_SHA_CONTEXTS] = {0};
static mbedtls_sha1_context s_sha1_ctx[MAX_SHA_CONTEXTS];
static int s_sha1_used[MAX_SHA_CONTEXTS] = {0};

/* SHA-256 streaming */
int bk_zig_sha256_init(void) {
    for (int i = 0; i < MAX_SHA_CONTEXTS; i++) {
        if (!s_sha256_used[i]) {
            s_sha256_used[i] = 1;
            mbedtls_sha256_init(&s_sha256_ctx[i]);
            mbedtls_sha256_starts(&s_sha256_ctx[i], 0);
            return i;
        }
    }
    return -1;
}

int bk_zig_sha256_update(int handle, const unsigned char *data, unsigned int len) {
    if (handle < 0 || handle >= MAX_SHA_CONTEXTS || !s_sha256_used[handle]) return -1;
    return mbedtls_sha256_update(&s_sha256_ctx[handle], data, len);
}

int bk_zig_sha256_final(int handle, unsigned char output[32]) {
    if (handle < 0 || handle >= MAX_SHA_CONTEXTS || !s_sha256_used[handle]) return -1;
    int ret = mbedtls_sha256_finish(&s_sha256_ctx[handle], output);
    mbedtls_sha256_free(&s_sha256_ctx[handle]);
    s_sha256_used[handle] = 0;
    return ret;
}

/* SHA-384 streaming (uses sha512 context with is384=1) */
int bk_zig_sha384_init(void) {
    for (int i = 0; i < MAX_SHA_CONTEXTS; i++) {
        if (!s_sha512_used[i]) {
            s_sha512_used[i] = 1;
            mbedtls_sha512_init(&s_sha512_ctx[i]);
            mbedtls_sha512_starts(&s_sha512_ctx[i], 1); /* 1 = SHA-384 */
            return i;
        }
    }
    return -1;
}

int bk_zig_sha384_update(int handle, const unsigned char *data, unsigned int len) {
    if (handle < 0 || handle >= MAX_SHA_CONTEXTS || !s_sha512_used[handle]) return -1;
    return mbedtls_sha512_update(&s_sha512_ctx[handle], data, len);
}

int bk_zig_sha384_final(int handle, unsigned char output[48]) {
    if (handle < 0 || handle >= MAX_SHA_CONTEXTS || !s_sha512_used[handle]) return -1;
    unsigned char full[64];
    int ret = mbedtls_sha512_finish(&s_sha512_ctx[handle], full);
    if (ret == 0) memcpy(output, full, 48);
    mbedtls_sha512_free(&s_sha512_ctx[handle]);
    s_sha512_used[handle] = 0;
    return ret;
}

/* SHA-512 streaming */
int bk_zig_sha512_init(void) {
    /* Use separate tracking to avoid colliding with SHA-384 */
    /* Actually sha384 and sha512 share s_sha512_ctx, so we need a different pool */
    /* For simplicity, reuse the same pool — caller must not use both sha384 and sha512 simultaneously beyond MAX_SHA_CONTEXTS */
    for (int i = 0; i < MAX_SHA_CONTEXTS; i++) {
        if (!s_sha512_used[i]) {
            s_sha512_used[i] = 1;
            mbedtls_sha512_init(&s_sha512_ctx[i]);
            mbedtls_sha512_starts(&s_sha512_ctx[i], 0); /* 0 = SHA-512 */
            return i;
        }
    }
    return -1;
}

int bk_zig_sha512_update(int handle, const unsigned char *data, unsigned int len) {
    return bk_zig_sha384_update(handle, data, len); /* Same ctx pool */
}

int bk_zig_sha512_final(int handle, unsigned char output[64]) {
    if (handle < 0 || handle >= MAX_SHA_CONTEXTS || !s_sha512_used[handle]) return -1;
    int ret = mbedtls_sha512_finish(&s_sha512_ctx[handle], output);
    mbedtls_sha512_free(&s_sha512_ctx[handle]);
    s_sha512_used[handle] = 0;
    return ret;
}

/* SHA-1 streaming */
int bk_zig_sha1_init(void) {
    for (int i = 0; i < MAX_SHA_CONTEXTS; i++) {
        if (!s_sha1_used[i]) {
            s_sha1_used[i] = 1;
            mbedtls_sha1_init(&s_sha1_ctx[i]);
            mbedtls_sha1_starts(&s_sha1_ctx[i]);
            return i;
        }
    }
    return -1;
}

int bk_zig_sha1_update(int handle, const unsigned char *data, unsigned int len) {
    if (handle < 0 || handle >= MAX_SHA_CONTEXTS || !s_sha1_used[handle]) return -1;
    return mbedtls_sha1_update(&s_sha1_ctx[handle], data, len);
}

int bk_zig_sha1_final(int handle, unsigned char output[20]) {
    if (handle < 0 || handle >= MAX_SHA_CONTEXTS || !s_sha1_used[handle]) return -1;
    int ret = mbedtls_sha1_finish(&s_sha1_ctx[handle], output);
    mbedtls_sha1_free(&s_sha1_ctx[handle]);
    s_sha1_used[handle] = 0;
    return ret;
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

/* HKDF implemented via HMAC (mbedtls_hkdf not linked in Armino) */

int bk_zig_hkdf_extract(
    const unsigned char *salt, unsigned int salt_len,
    const unsigned char *ikm, unsigned int ikm_len,
    unsigned char *prk, unsigned int hash_len)
{
    /* HKDF-Extract: PRK = HMAC-Hash(salt, IKM) */
    const mbedtls_md_info_t *md;
    if (hash_len == 32) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    else if (hash_len == 48) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA384);
    else if (hash_len == 64) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA512);
    else return -1;

    /* If salt is NULL, use hash_len zeros */
    unsigned char zero_salt[64] = {0};
    const unsigned char *actual_salt = salt;
    unsigned int actual_salt_len = salt_len;
    if (actual_salt == NULL || actual_salt_len == 0) {
        actual_salt = zero_salt;
        actual_salt_len = hash_len;
    }

    return mbedtls_md_hmac(md, actual_salt, actual_salt_len, ikm, ikm_len, prk);
}

int bk_zig_hkdf_expand(
    const unsigned char *prk, unsigned int prk_len,
    const unsigned char *info, unsigned int info_len,
    unsigned char *okm, unsigned int okm_len)
{
    /* HKDF-Expand: OKM = T(1) || T(2) || ... where T(i) = HMAC-Hash(PRK, T(i-1) || info || i) */
    const mbedtls_md_info_t *md;
    if (prk_len == 32) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    else if (prk_len == 48) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA384);
    else if (prk_len == 64) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA512);
    else return -1;

    unsigned int hash_len = prk_len;
    unsigned int n = (okm_len + hash_len - 1) / hash_len;
    if (n > 255) return -1;

    mbedtls_md_context_t ctx;
    mbedtls_md_init(&ctx);
    int ret = mbedtls_md_setup(&ctx, md, 1);
    if (ret != 0) { mbedtls_md_free(&ctx); return ret; }

    unsigned char t[64] = {0}; /* Previous T block */
    unsigned int t_len = 0;
    unsigned int done = 0;

    for (unsigned int i = 1; i <= n; i++) {
        unsigned char counter = (unsigned char)i;

        ret = mbedtls_md_hmac_starts(&ctx, prk, prk_len);
        if (ret != 0) break;
        if (t_len > 0) {
            ret = mbedtls_md_hmac_update(&ctx, t, t_len);
            if (ret != 0) break;
        }
        if (info_len > 0) {
            ret = mbedtls_md_hmac_update(&ctx, info, info_len);
            if (ret != 0) break;
        }
        ret = mbedtls_md_hmac_update(&ctx, &counter, 1);
        if (ret != 0) break;
        ret = mbedtls_md_hmac_finish(&ctx, t);
        if (ret != 0) break;
        t_len = hash_len;

        unsigned int copy_len = (okm_len - done < hash_len) ? okm_len - done : hash_len;
        memcpy(okm + done, t, copy_len);
        done += copy_len;
    }

    mbedtls_md_free(&ctx);
    return ret;
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
 * HMAC streaming (init/update/final with context handles)
 * ======================================================================== */

#define MAX_HMAC_CONTEXTS 4

static mbedtls_md_context_t s_hmac_ctx[MAX_HMAC_CONTEXTS];
static int s_hmac_used[MAX_HMAC_CONTEXTS] = {0};

int bk_zig_hmac_init(unsigned int hash_len,
                      const unsigned char *key, unsigned int key_len) {
    const mbedtls_md_info_t *md;
    if (hash_len == 32) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    else if (hash_len == 48) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA384);
    else if (hash_len == 64) md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA512);
    else return -1;

    for (int i = 0; i < MAX_HMAC_CONTEXTS; i++) {
        if (!s_hmac_used[i]) {
            s_hmac_used[i] = 1;
            mbedtls_md_init(&s_hmac_ctx[i]);
            if (mbedtls_md_setup(&s_hmac_ctx[i], md, 1) != 0) {
                s_hmac_used[i] = 0;
                return -1;
            }
            if (mbedtls_md_hmac_starts(&s_hmac_ctx[i], key, key_len) != 0) {
                mbedtls_md_free(&s_hmac_ctx[i]);
                s_hmac_used[i] = 0;
                return -1;
            }
            return i;
        }
    }
    return -1;
}

int bk_zig_hmac_update(int handle, const unsigned char *data, unsigned int len) {
    if (handle < 0 || handle >= MAX_HMAC_CONTEXTS || !s_hmac_used[handle]) return -1;
    return mbedtls_md_hmac_update(&s_hmac_ctx[handle], data, len);
}

int bk_zig_hmac_final(int handle, unsigned char *output) {
    if (handle < 0 || handle >= MAX_HMAC_CONTEXTS || !s_hmac_used[handle]) return -1;
    int ret = mbedtls_md_hmac_finish(&s_hmac_ctx[handle], output);
    mbedtls_md_free(&s_hmac_ctx[handle]);
    s_hmac_used[handle] = 0;
    return ret;
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
    if (ret != 0) goto p384v_cleanup;

    ret = mbedtls_ecp_point_read_binary(&grp, &Q, pk, 97);
    if (ret != 0) goto p384v_cleanup;

    ret = mbedtls_mpi_read_binary(&r_mpi, r, 48);
    if (ret != 0) goto p384v_cleanup;
    ret = mbedtls_mpi_read_binary(&s_mpi, s, 48);
    if (ret != 0) goto p384v_cleanup;

    ret = mbedtls_ecdsa_verify(&grp, hash, 48, &Q, &r_mpi, &s_mpi);

p384v_cleanup:
    mbedtls_mpi_free(&s_mpi);
    mbedtls_mpi_free(&r_mpi);
    mbedtls_ecp_point_free(&Q);
    mbedtls_ecp_group_free(&grp);
    return ret;
}

/* ========================================================================
 * X25519 (Curve25519 ECDH) — requires MBEDTLS_ECP_DP_CURVE25519_ENABLED
 * ======================================================================== */

int bk_zig_x25519_keypair(
    const unsigned char seed[32],
    unsigned char sk_out[32],
    unsigned char pk_out[32])
{
#if defined(MBEDTLS_ECP_DP_CURVE25519_ENABLED)
    mbedtls_ecp_group grp;
    mbedtls_mpi d;
    mbedtls_ecp_point Q;
    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&Q);

    int ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_CURVE25519);
    if (ret != 0) goto x25519_kp_end;

    unsigned char clamped[32];
    memcpy(clamped, seed, 32);
    clamped[0] &= 248;
    clamped[31] &= 127;
    clamped[31] |= 64;

    unsigned char sk_be[32];
    for (int i = 0; i < 32; i++) sk_be[i] = clamped[31 - i];
    ret = mbedtls_mpi_read_binary(&d, sk_be, 32);
    if (ret != 0) goto x25519_kp_end;

    ret = mbedtls_ecp_mul(&grp, &Q, &d, &grp.G, bk_rng_callback, NULL);
    if (ret != 0) goto x25519_kp_end;

    memcpy(sk_out, clamped, 32);
    unsigned char pk_be[32];
    ret = mbedtls_mpi_write_binary(&Q.MBEDTLS_PRIVATE(X), pk_be, 32);
    if (ret != 0) goto x25519_kp_end;
    for (int i = 0; i < 32; i++) pk_out[i] = pk_be[31 - i];

x25519_kp_end:
    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return ret;
#else
    (void)seed; (void)sk_out; (void)pk_out;
    return -1;
#endif
}

int bk_zig_x25519_scalarmult(
    const unsigned char sk[32],
    const unsigned char pk[32],
    unsigned char out[32])
{
#if defined(MBEDTLS_ECP_DP_CURVE25519_ENABLED)
    mbedtls_ecp_group grp;
    mbedtls_mpi d, z;
    mbedtls_ecp_point Q;
    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_mpi_init(&z);
    mbedtls_ecp_point_init(&Q);

    int ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_CURVE25519);
    if (ret != 0) goto x25519_sm_end;

    unsigned char sk_be[32];
    for (int i = 0; i < 32; i++) sk_be[i] = sk[31 - i];
    ret = mbedtls_mpi_read_binary(&d, sk_be, 32);
    if (ret != 0) goto x25519_sm_end;

    unsigned char pk_be[32];
    for (int i = 0; i < 32; i++) pk_be[i] = pk[31 - i];
    ret = mbedtls_mpi_read_binary(&Q.MBEDTLS_PRIVATE(X), pk_be, 32);
    if (ret != 0) goto x25519_sm_end;
    ret = mbedtls_mpi_lset(&Q.MBEDTLS_PRIVATE(Z), 1);
    if (ret != 0) goto x25519_sm_end;

    ret = mbedtls_ecdh_compute_shared(&grp, &z, &Q, &d, bk_rng_callback, NULL);
    if (ret != 0) goto x25519_sm_end;

    unsigned char z_be[32];
    ret = mbedtls_mpi_write_binary(&z, z_be, 32);
    if (ret != 0) goto x25519_sm_end;
    for (int i = 0; i < 32; i++) out[i] = z_be[31 - i];

x25519_sm_end:
    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&z);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return ret;
#else
    (void)sk; (void)pk; (void)out;
    return -1;
#endif
}
