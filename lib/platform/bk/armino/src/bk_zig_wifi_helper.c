/**
 * bk_zig_wifi_helper.c — WiFi + Event + Netif helpers for Zig interop.
 *
 * Wraps Armino WiFi STA, event registration, and netif APIs.
 * Handles event callbacks from C → Zig via function pointers.
 */

#include <os/os.h>
#include <components/log.h>
#include <components/event.h>
#include <components/netif.h>
#include <modules/wifi.h>

#define TAG "zig_wifi"

/* ========================================================================
 * Callback storage — Zig registers callbacks, C dispatches events
 * ======================================================================== */

typedef void (*zig_wifi_event_cb_t)(int event_id, void *event_data, int data_len);
typedef void (*zig_netif_event_cb_t)(int event_id, const char *ip);

static zig_wifi_event_cb_t s_wifi_cb = NULL;
static zig_netif_event_cb_t s_netif_cb = NULL;

/* C event handler → dispatches to Zig callback */
static bk_err_t wifi_event_handler(void *arg, event_module_t mod, int event_id,
                                   void *event_data) {
    if (s_wifi_cb) {
        int data_len = 0;
        switch (event_id) {
            case EVENT_WIFI_STA_CONNECTED:
                data_len = sizeof(wifi_event_sta_connected_t);
                break;
            case EVENT_WIFI_STA_DISCONNECTED:
                data_len = sizeof(wifi_event_sta_disconnected_t);
                break;
            case EVENT_WIFI_SCAN_DONE:
                data_len = sizeof(wifi_event_scan_done_t);
                break;
        }
        s_wifi_cb(event_id, event_data, data_len);
    }
    return BK_OK;
}

static bk_err_t netif_event_handler(void *arg, event_module_t mod, int event_id,
                                    void *event_data) {
    if (s_netif_cb) {
        const char *ip = "";
        if (event_id == EVENT_NETIF_GOT_IP4 && event_data) {
            netif_event_got_ip4_t *got_ip = (netif_event_got_ip4_t *)event_data;
            ip = got_ip->ip;
        }
        s_netif_cb(event_id, ip);
    }
    return BK_OK;
}

/* ========================================================================
 * WiFi init / connect / disconnect
 * ======================================================================== */

int bk_zig_wifi_init(void) {
    /* WiFi is typically already initialized by bk_init() on CP.
     * On AP, we just need to register events. */
    return BK_OK;
}

int bk_zig_wifi_register_events(zig_wifi_event_cb_t wifi_cb,
                                zig_netif_event_cb_t netif_cb) {
    s_wifi_cb = wifi_cb;
    s_netif_cb = netif_cb;

    bk_err_t ret;

    /* Register WiFi events */
    ret = bk_event_register_cb(EVENT_MOD_WIFI, EVENT_ID_ALL,
                               wifi_event_handler, NULL);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "wifi event register failed: %d\r\n", ret);
        return ret;
    }

    /* Register Netif events (IP) */
    ret = bk_event_register_cb(EVENT_MOD_NETIF, EVENT_ID_ALL,
                               netif_event_handler, NULL);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "netif event register failed: %d\r\n", ret);
        return ret;
    }

    BK_LOGI(TAG, "WiFi + Netif events registered\r\n");
    return BK_OK;
}

int bk_zig_wifi_sta_connect(const char *ssid, const char *password) {
    wifi_sta_config_t sta_config = {0};

    /* Copy SSID */
    int ssid_len = strlen(ssid);
    if (ssid_len > sizeof(sta_config.ssid) - 1)
        ssid_len = sizeof(sta_config.ssid) - 1;
    memcpy(sta_config.ssid, ssid, ssid_len);

    /* Copy password */
    if (password && strlen(password) > 0) {
        int pwd_len = strlen(password);
        if (pwd_len > sizeof(sta_config.password) - 1)
            pwd_len = sizeof(sta_config.password) - 1;
        memcpy(sta_config.password, password, pwd_len);
    }

    BK_LOGI(TAG, "Connecting to '%s'...\r\n", ssid);

    bk_err_t ret = bk_wifi_sta_set_config(&sta_config);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "sta_set_config failed: %d\r\n", ret);
        return ret;
    }

    ret = bk_wifi_sta_start();
    if (ret != BK_OK) {
        BK_LOGE(TAG, "sta_start failed: %d\r\n", ret);
        return ret;
    }

    ret = bk_wifi_sta_connect();
    if (ret != BK_OK) {
        BK_LOGE(TAG, "sta_connect failed: %d\r\n", ret);
        return ret;
    }

    return BK_OK;
}

int bk_zig_wifi_sta_disconnect(void) {
    return bk_wifi_sta_disconnect();
}

/* ========================================================================
 * Netif — get IP info
 * ======================================================================== */

int bk_zig_netif_get_ip4(unsigned char *ip_out, unsigned char *dns_out) {
    netif_ip4_config_t config;
    bk_err_t ret = bk_netif_get_ip4_config(NETIF_IF_STA, &config);
    if (ret != BK_OK) return ret;

    /* Parse IP string to 4 bytes */
    if (ip_out) {
        unsigned int a, b, c, d;
        if (sscanf(config.ip, "%u.%u.%u.%u", &a, &b, &c, &d) == 4) {
            ip_out[0] = a; ip_out[1] = b; ip_out[2] = c; ip_out[3] = d;
        }
    }
    if (dns_out) {
        unsigned int a, b, c, d;
        if (sscanf(config.dns, "%u.%u.%u.%u", &a, &b, &c, &d) == 4) {
            dns_out[0] = a; dns_out[1] = b; dns_out[2] = c; dns_out[3] = d;
        }
    }
    return BK_OK;
}
