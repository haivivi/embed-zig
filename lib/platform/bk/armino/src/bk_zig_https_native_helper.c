/**
 * bk_zig_https_native_helper.c — Native mbedTLS HTTPS speed test
 *
 * Uses Armino's mbedTLS directly (not Zig TLS) for baseline comparison.
 * Called from Zig after WiFi is connected.
 *
 * Measures: DNS, TCP connect, TLS handshake, HTTP download — each separately.
 */

#include <string.h>
#include <components/log.h>
#include <lwip/sockets.h>
#include <lwip/netdb.h>
#include <os/os.h>

#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/error.h"

#define TAG "native_https"

/* Get monotonic time in ms */
static uint32_t now_ms(void) {
    return rtos_get_time();
}

/* RNG callback using bk_rand */
extern int bk_rand(void);
static int my_rng(void *ctx, unsigned char *output, size_t len) {
    (void)ctx;
    size_t i = 0;
    while (i + 4 <= len) {
        int r = bk_rand();
        memcpy(output + i, &r, 4);
        i += 4;
    }
    if (i < len) {
        int r = bk_rand();
        memcpy(output + i, &r, len - i);
    }
    return 0;
}

/**
 * Run a single native HTTPS test.
 * Returns 0 on success, -1 on error.
 */
static int run_native_test(const char *host, const char *path, const char *test_name, int range_end) {
    uint32_t t_start, t_dns, t_tcp, t_tls, t_body_start, t_end;
    int ret;
    char err_buf[128];

    BK_LOGI(TAG, "\r\n");
    BK_LOGI(TAG, "--- [NATIVE] %s ---\r\n", test_name);
    BK_LOGI(TAG, "Host: %s, Path: %s\r\n", host, path);

    t_start = now_ms();

    /* ---- DNS ---- */
    BK_LOGI(TAG, "DNS resolving...\r\n");
    struct addrinfo hints = {0};
    struct addrinfo *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    ret = getaddrinfo(host, "443", &hints, &res);
    if (ret != 0 || res == NULL) {
        BK_LOGE(TAG, "DNS failed: %d\r\n", ret);
        return -1;
    }
    t_dns = now_ms();

    struct sockaddr_in *addr_in = (struct sockaddr_in *)res->ai_addr;
    uint8_t *ip = (uint8_t *)&addr_in->sin_addr.s_addr;
    BK_LOGI(TAG, "Resolved: %d.%d.%d.%d (%d ms)\r\n",
            ip[0], ip[1], ip[2], ip[3], t_dns - t_start);

    /* ---- TCP connect ---- */
    BK_LOGI(TAG, "TCP connecting...\r\n");
    int sockfd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sockfd < 0) {
        BK_LOGE(TAG, "socket() failed\r\n");
        freeaddrinfo(res);
        return -1;
    }

    /* Set timeouts */
    struct timeval tv;
    tv.tv_sec = 30;
    tv.tv_usec = 0;
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    ret = connect(sockfd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (ret != 0) {
        BK_LOGE(TAG, "connect() failed: %d\r\n", ret);
        close(sockfd);
        return -1;
    }
    t_tcp = now_ms();
    BK_LOGI(TAG, "TCP connected (%d ms)\r\n", t_tcp - t_dns);

    /* ---- mbedTLS handshake ---- */
    BK_LOGI(TAG, "TLS handshake (mbedTLS native, no verify)...\r\n");

    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;

    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);

    ret = mbedtls_ctr_drbg_seed(&ctr_drbg, my_rng, NULL, NULL, 0);
    if (ret != 0) {
        mbedtls_strerror(ret, err_buf, sizeof(err_buf));
        BK_LOGE(TAG, "ctr_drbg_seed failed: %s (0x%x)\r\n", err_buf, -ret);
        goto cleanup;
    }

    ret = mbedtls_ssl_config_defaults(&conf,
                                       MBEDTLS_SSL_IS_CLIENT,
                                       MBEDTLS_SSL_TRANSPORT_STREAM,
                                       MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        BK_LOGE(TAG, "ssl_config_defaults failed: 0x%x\r\n", -ret);
        goto cleanup;
    }

    /* Skip certificate verification (same as Zig test) */
    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
    mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &ctr_drbg);

    ret = mbedtls_ssl_setup(&ssl, &conf);
    if (ret != 0) {
        BK_LOGE(TAG, "ssl_setup failed: 0x%x\r\n", -ret);
        goto cleanup;
    }

    ret = mbedtls_ssl_set_hostname(&ssl, host);
    if (ret != 0) {
        BK_LOGE(TAG, "set_hostname failed: 0x%x\r\n", -ret);
        goto cleanup;
    }

    /* Set socket fd for mbedTLS */
    mbedtls_ssl_set_bio(&ssl,
                         &sockfd,
                         /* send callback */
                         NULL,
                         /* recv callback */
                         NULL,
                         NULL);

    /* Use custom send/recv that wraps lwip */
    /* mbedtls_net_context uses fd directly, but we have a raw sockfd.
     * Use the low-level I/O callbacks. */
    mbedtls_ssl_set_bio(&ssl, &sockfd,
        /* send */
        (int (*)(void*, const unsigned char*, size_t))
        NULL,
        /* recv */
        NULL,
        NULL);

    /* Actually, we need proper I/O callbacks for the raw socket fd. */
    /* mbedTLS needs send/recv callbacks. Let's use simple wrappers. */

    /* Overwrite with proper lambdas (C function pointers) */

    /* Done above incorrectly - let me use mbedtls_net_context properly */
    mbedtls_net_context net_ctx;
    mbedtls_net_init(&net_ctx);
    net_ctx.fd = sockfd;

    mbedtls_ssl_set_bio(&ssl, &net_ctx,
                         mbedtls_net_send,
                         mbedtls_net_recv,
                         NULL);

    /* Perform handshake */
    while ((ret = mbedtls_ssl_handshake(&ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ &&
            ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            mbedtls_strerror(ret, err_buf, sizeof(err_buf));
            BK_LOGE(TAG, "TLS handshake failed: %s (0x%x)\r\n", err_buf, -ret);
            goto cleanup;
        }
    }
    t_tls = now_ms();
    BK_LOGI(TAG, "TLS handshake: %d ms (cipher: %s)\r\n",
            t_tls - t_tcp,
            mbedtls_ssl_get_ciphersuite(&ssl));

    /* ---- HTTP GET ---- */
    {
        char request[512];
        int req_len;
        if (range_end > 0) {
            req_len = snprintf(request, sizeof(request),
                "GET %s HTTP/1.1\r\n"
                "Host: %s\r\n"
                "Range: bytes=0-%d\r\n"
                "Connection: close\r\n"
                "\r\n",
                path, host, range_end);
        } else {
            req_len = snprintf(request, sizeof(request),
                "GET %s HTTP/1.1\r\n"
                "Host: %s\r\n"
                "Connection: close\r\n"
                "\r\n",
                path, host);
        }

        ret = mbedtls_ssl_write(&ssl, (unsigned char *)request, req_len);
        if (ret < 0) {
            BK_LOGE(TAG, "ssl_write failed: 0x%x\r\n", -ret);
            goto cleanup;
        }
    }

    /* ---- Receive response ---- */
    {
        unsigned char recv_buf[4096];
        int total_bytes = 0;
        int last_print = 0;
        int header_done = 0;
        int total_raw = 0;
        t_body_start = 0;

        int read_count = 0;
        while (1) {
            ret = mbedtls_ssl_read(&ssl, recv_buf, sizeof(recv_buf));
            read_count++;
            if (ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
                BK_LOGI(TAG, "read #%d: PEER_CLOSE_NOTIFY\r\n", read_count);
                break;
            }
            if (ret == 0) {
                BK_LOGI(TAG, "read #%d: EOF (0)\r\n", read_count);
                break;
            }
            if (ret < 0) {
                if (ret == MBEDTLS_ERR_SSL_WANT_READ ||
                    ret == MBEDTLS_ERR_SSL_WANT_WRITE) {
                    continue;
                }
                mbedtls_strerror(ret, err_buf, sizeof(err_buf));
                BK_LOGI(TAG, "read #%d: error %s (0x%x)\r\n", read_count, err_buf, -ret);
                break;
            }
            if (read_count <= 3 || total_raw == 0) {
                BK_LOGI(TAG, "read #%d: %d bytes\r\n", read_count, ret);
            }

            total_raw += ret;
            if (t_body_start == 0) t_body_start = now_ms();

            if (!header_done) {
                /* Manual search for \r\n\r\n (memmem may not exist) */
                for (int i = 0; i + 3 < ret; i++) {
                    if (recv_buf[i] == '\r' && recv_buf[i+1] == '\n' &&
                        recv_buf[i+2] == '\r' && recv_buf[i+3] == '\n') {
                        int hdr_len = i + 4;
                        total_bytes += ret - hdr_len;
                        header_done = 1;
                        break;
                    }
                }
            } else {
                total_bytes += ret;
            }

            if (total_bytes - last_print >= 100 * 1024) {
                uint32_t elapsed = now_ms() - t_body_start;
                uint32_t speed = elapsed > 0 ? (total_bytes / 1024 * 1000 / elapsed) : 0;
                BK_LOGI(TAG, "Progress: %d KB (%d KB/s)\r\n", total_bytes / 1024, speed);
                last_print = total_bytes;
            }
        }

        BK_LOGI(TAG, "Total raw received: %d bytes (body: %d)\r\n", total_raw, total_bytes);

        t_end = now_ms();
        uint32_t body_ms = t_body_start > 0 ? (t_end - t_body_start) : (t_end - t_start);
        uint32_t speed = body_ms > 0 ? (total_bytes / 1024 * 1000 / body_ms) : 0;

        BK_LOGI(TAG, "Downloaded: %d bytes in %d ms (handshake: %d ms)\r\n",
                total_bytes, t_end - t_start, t_tls - t_tcp);
        BK_LOGI(TAG, "Speed: %d KB/s\r\n", speed);
    }

    mbedtls_ssl_close_notify(&ssl);

cleanup:
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_entropy_free(&entropy);
    close(sockfd);
    return 0;
}

/**
 * Entry point called from Zig after WiFi is connected.
 * Runs the same tests as the Zig https_speed_test for comparison.
 */
void bk_native_https_test(void) {
    BK_LOGI(TAG, "========================================\r\n");
    BK_LOGI(TAG, "  Native mbedTLS HTTPS Speed Test\r\n");
    BK_LOGI(TAG, "========================================\r\n");

    rtos_delay_milliseconds(1000);

    /* Test 1: Small HTTPS request (1KB range) */
    run_native_test("dldir1.qq.com", "/weixin/Windows/WeChatSetup.exe",
                    "HTTPS 1KB (qq CDN)", 1023);

    rtos_delay_milliseconds(2000);

    /* Test 2: 100KB download (range request) */
    run_native_test("dldir1.qq.com", "/weixin/Windows/WeChatSetup.exe",
                    "HTTPS 100KB (qq CDN)", 102399);

    BK_LOGI(TAG, "\r\n");
    BK_LOGI(TAG, "=== [NATIVE] All Tests Complete ===\r\n");
}
