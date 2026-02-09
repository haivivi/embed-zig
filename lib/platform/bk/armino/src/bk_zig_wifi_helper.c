/**
 * bk_zig_wifi_helper.c — WiFi + Event + Netif helpers for Zig interop.
 *
 * Wraps Armino WiFi STA, event registration, and netif APIs.
 * Handles event callbacks from C → Zig via function pointers.
 */

#include <os/os.h>
#include <string.h>
#include <stdio.h>
#include <components/log.h>
#include <components/event.h>
#include <components/netif.h>
#include <modules/wifi.h>

#define TAG "zig_wifi"

/* ========================================================================
 * Event queue (C-side) — Zig polls via bk_zig_wifi_poll_event()
 * ======================================================================== */

#define MAX_EVENTS 16

/* Event types matching Zig's WifiEvent union */
#define EVT_NONE          0
#define EVT_CONNECTED     1
#define EVT_DISCONNECTED  2
#define EVT_GOT_IP        3
#define EVT_DHCP_TIMEOUT  4
#define EVT_SCAN_DONE     5

typedef struct {
    int type;
    unsigned char ip[4];
    unsigned char dns[4];
} bk_zig_event_t;

static bk_zig_event_t s_events[MAX_EVENTS];
static volatile int s_head = 0;
static volatile int s_tail = 0;

static void push_event(bk_zig_event_t ev) {
    s_events[s_tail] = ev;
    s_tail = (s_tail + 1) % MAX_EVENTS;
    if (s_tail == s_head) s_head = (s_head + 1) % MAX_EVENTS; /* overflow: drop oldest */
}

/* Called from Zig to poll events */
int bk_zig_wifi_poll_event(int *out_type, unsigned char *out_ip, unsigned char *out_dns) {
    if (s_head == s_tail) return 0; /* no events */
    bk_zig_event_t *ev = &s_events[s_head];
    *out_type = ev->type;
    if (out_ip) { memcpy(out_ip, ev->ip, 4); }
    if (out_dns) { memcpy(out_dns, ev->dns, 4); }
    s_head = (s_head + 1) % MAX_EVENTS;
    return 1;
}

/* C event handlers */
static bk_err_t wifi_event_handler(void *arg, event_module_t mod, int event_id,
                                   void *event_data) {
    bk_zig_event_t ev = {0};
    switch (event_id) {
        case EVENT_WIFI_STA_CONNECTED:
            ev.type = EVT_CONNECTED;
            BK_LOGI(TAG, "event: STA connected\r\n");
            break;
        case EVENT_WIFI_STA_DISCONNECTED:
            ev.type = EVT_DISCONNECTED;
            BK_LOGI(TAG, "event: STA disconnected\r\n");
            break;
        case EVENT_WIFI_SCAN_DONE:
            ev.type = EVT_SCAN_DONE;
            break;
        default:
            return BK_OK;
    }
    push_event(ev);
    return BK_OK;
}

static bk_err_t netif_event_handler(void *arg, event_module_t mod, int event_id,
                                    void *event_data) {
    bk_zig_event_t ev = {0};
    switch (event_id) {
        case EVENT_NETIF_GOT_IP4: {
            ev.type = EVT_GOT_IP;
            /* Get IP and DNS from netif */
            netif_ip4_config_t config;
            if (bk_netif_get_ip4_config(NETIF_IF_STA, &config) == BK_OK) {
                unsigned int a,b,c,d;
                if (sscanf(config.ip, "%u.%u.%u.%u", &a,&b,&c,&d) == 4) {
                    ev.ip[0]=a; ev.ip[1]=b; ev.ip[2]=c; ev.ip[3]=d;
                }
                if (sscanf(config.dns, "%u.%u.%u.%u", &a,&b,&c,&d) == 4) {
                    ev.dns[0]=a; ev.dns[1]=b; ev.dns[2]=c; ev.dns[3]=d;
                }
            }
            BK_LOGI(TAG, "event: got IP %d.%d.%d.%d dns %d.%d.%d.%d\r\n",
                    ev.ip[0],ev.ip[1],ev.ip[2],ev.ip[3],
                    ev.dns[0],ev.dns[1],ev.dns[2],ev.dns[3]);
            break;
        }
        case EVENT_NETIF_DHCP_TIMEOUT:
            ev.type = EVT_DHCP_TIMEOUT;
            BK_LOGW(TAG, "event: DHCP timeout\r\n");
            break;
        default:
            return BK_OK;
    }
    push_event(ev);
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

int bk_zig_wifi_register_events(void) {
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
    bk_err_t ret = bk_wifi_sta_disconnect();
    /* Armino's bk_wifi_sta_disconnect() does NOT post EVENT_WIFI_STA_DISCONNECTED.
     * We push it manually so Zig's event loop gets notified. */
    if (ret == BK_OK) {
        bk_zig_event_t ev = {0};
        ev.type = EVT_DISCONNECTED;
        push_event(ev);
        BK_LOGI(TAG, "event: STA disconnected (manual)\r\n");
    }
    return ret;
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
