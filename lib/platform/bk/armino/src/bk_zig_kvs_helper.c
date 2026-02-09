/**
 * bk_zig_kvs_helper.c — Key-Value Store via EasyFlash V4
 *
 * Wraps bk_set_env_enhance / bk_get_env_enhance for binary KV storage.
 */

#include <string.h>
#include <components/log.h>

/* EasyFlash V4 API */
extern int bk_get_env_enhance(const char *key, void *value, int value_len);
extern int bk_set_env_enhance(const char *key, const void *value, int value_len);
extern int bk_save_env(void);

#define TAG "zig_kvs"

int bk_zig_kvs_get(const char *key, unsigned int key_len,
                     void *value, unsigned int value_len) {
    /* bk_get_env_enhance expects null-terminated key */
    char key_buf[64];
    unsigned int kl = key_len < 63 ? key_len : 63;
    memcpy(key_buf, key, kl);
    key_buf[kl] = '\0';

    int ret = bk_get_env_enhance(key_buf, value, (int)value_len);
    /* Returns actual length on success, 0 on not found */
    return ret;
}

int bk_zig_kvs_set(const char *key, unsigned int key_len,
                     const void *value, unsigned int value_len) {
    char key_buf[64];
    unsigned int kl = key_len < 63 ? key_len : 63;
    memcpy(key_buf, key, kl);
    key_buf[kl] = '\0';

    int ret = bk_set_env_enhance(key_buf, value, (int)value_len);
    return ret; /* 0 = EF_NO_ERR */
}

int bk_zig_kvs_commit(void) {
    return bk_save_env();
}
