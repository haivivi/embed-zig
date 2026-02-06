/**
 * HKDF Helper Implementation
 * 
 * Implements HKDF (RFC 5869) using mbedTLS HMAC functions.
 * This is needed because the mbedTLS HKDF module may not be enabled
 * in some sdkconfig configurations.
 */

#include "hkdf_helper.h"
#include <string.h>
#include <mbedtls/md.h>

/* Maximum hash output size (SHA-512 = 64 bytes) */
#define MAX_HASH_SIZE 64

int hkdf_extract(
    const uint8_t *salt, size_t salt_len,
    const uint8_t *ikm, size_t ikm_len,
    uint8_t *prk, size_t hash_len)
{
    mbedtls_md_type_t md_type;
    const mbedtls_md_info_t *md_info;
    uint8_t null_salt[MAX_HASH_SIZE] = {0};
    int ret;
    
    /* Determine hash algorithm based on output length */
    if (hash_len == 32) {
        md_type = MBEDTLS_MD_SHA256;
    } else if (hash_len == 48) {
        md_type = MBEDTLS_MD_SHA384;
    } else if (hash_len == 64) {
        md_type = MBEDTLS_MD_SHA512;
    } else {
        return -1;  /* Unsupported hash size */
    }
    
    md_info = mbedtls_md_info_from_type(md_type);
    if (md_info == NULL) {
        return -1;
    }
    
    /* If salt is NULL, use hash_len zeros */
    if (salt == NULL || salt_len == 0) {
        salt = null_salt;
        salt_len = hash_len;
    }
    
    /* PRK = HMAC-Hash(salt, IKM) */
    ret = mbedtls_md_hmac(md_info, salt, salt_len, ikm, ikm_len, prk);
    
    return ret;
}

int hkdf_expand(
    const uint8_t *prk, size_t prk_len,
    const uint8_t *info, size_t info_len,
    uint8_t *okm, size_t okm_len)
{
    mbedtls_md_type_t md_type;
    const mbedtls_md_info_t *md_info;
    mbedtls_md_context_t ctx;
    uint8_t t[MAX_HASH_SIZE];  /* T(i) */
    uint8_t counter = 1;
    size_t hash_len;
    size_t remaining = okm_len;
    size_t t_len = 0;
    int ret = 0;
    
    /* Determine hash algorithm based on PRK length */
    if (prk_len == 32) {
        md_type = MBEDTLS_MD_SHA256;
        hash_len = 32;
    } else if (prk_len == 48) {
        md_type = MBEDTLS_MD_SHA384;
        hash_len = 48;
    } else if (prk_len == 64) {
        md_type = MBEDTLS_MD_SHA512;
        hash_len = 64;
    } else {
        return -1;
    }
    
    md_info = mbedtls_md_info_from_type(md_type);
    if (md_info == NULL) {
        return -1;
    }
    
    /* Check output length limit: L <= 255 * HashLen */
    if (okm_len > 255 * hash_len) {
        return -1;
    }
    
    mbedtls_md_init(&ctx);
    
    ret = mbedtls_md_setup(&ctx, md_info, 1);  /* 1 = use HMAC */
    if (ret != 0) {
        mbedtls_md_free(&ctx);
        return ret;
    }
    
    /* Generate OKM in blocks */
    while (remaining > 0) {
        ret = mbedtls_md_hmac_starts(&ctx, prk, prk_len);
        if (ret != 0) {
            break;
        }
        
        /* T(i) = HMAC-Hash(PRK, T(i-1) | info | i) */
        if (t_len > 0) {
            ret = mbedtls_md_hmac_update(&ctx, t, t_len);
            if (ret != 0) {
                break;
            }
        }
        
        if (info != NULL && info_len > 0) {
            ret = mbedtls_md_hmac_update(&ctx, info, info_len);
            if (ret != 0) {
                break;
            }
        }
        
        ret = mbedtls_md_hmac_update(&ctx, &counter, 1);
        if (ret != 0) {
            break;
        }
        
        ret = mbedtls_md_hmac_finish(&ctx, t);
        if (ret != 0) {
            break;
        }
        
        t_len = hash_len;
        
        /* Copy to output */
        size_t to_copy = (remaining >= hash_len) ? hash_len : remaining;
        memcpy(okm, t, to_copy);
        okm += to_copy;
        remaining -= to_copy;
        counter++;
    }
    
    mbedtls_md_free(&ctx);
    
    /* Clear sensitive data */
    memset(t, 0, sizeof(t));
    
    return ret;
}
