/**
 * WiFi Helper - Low-level ESP-IDF WiFi API wrapper
 *
 * Provides thin wrappers for ESP-IDF WiFi functions.
 * Does NOT handle netif creation or event loop - those are in idf/net and idf/event.
 */

#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include <stdlib.h>
#include <string.h>

static const char* TAG = "wifi_helper";

// WiFi mode constants
#define WIFI_MODE_STA_VAL   1
#define WIFI_MODE_AP_VAL    2
#define WIFI_MODE_APSTA_VAL 3

// Event group for connection wait
static EventGroupHandle_t s_wifi_event_group = NULL;
static const int WIFI_CONNECTED_BIT = BIT0;
static const int WIFI_FAIL_BIT = BIT1;

// State
static bool s_initialized = false;
static bool s_started = false;
static int s_retry_count = 0;
static int s_max_retry = 5;

// Scan state
static volatile bool s_scan_done = false;
static volatile bool s_scan_success = false;
static bool s_scan_handler_registered = false;

// STA event handler (for blocking connect)
static void sta_event_handler(void *arg, esp_event_base_t event_base,
                              int32_t event_id, void *event_data) {
    if (event_base == WIFI_EVENT) {
        if (event_id == WIFI_EVENT_STA_START) {
            esp_wifi_connect();
        } else if (event_id == WIFI_EVENT_STA_DISCONNECTED) {
            if (s_retry_count < s_max_retry) {
                esp_wifi_connect();
                s_retry_count++;
                ESP_LOGD(TAG, "Retry connect (%d/%d)", s_retry_count, s_max_retry);
            } else {
                if (s_wifi_event_group) {
                    xEventGroupSetBits(s_wifi_event_group, WIFI_FAIL_BIT);
                }
            }
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        s_retry_count = 0;
        if (s_wifi_event_group) {
            xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
        }
    }
}

// ============================================================================
// Initialization
// ============================================================================

int wifi_helper_init(void) {
    if (s_initialized) {
        ESP_LOGD(TAG, "WiFi already initialized");
        return 0;
    }

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t ret = esp_wifi_init(&cfg);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    s_initialized = true;
    ESP_LOGI(TAG, "WiFi initialized");
    return 0;
}

void wifi_helper_deinit(void) {
    if (!s_initialized) {
        return;
    }

    if (s_started) {
        esp_wifi_stop();
        s_started = false;
    }

    esp_wifi_deinit();
    s_initialized = false;
    ESP_LOGI(TAG, "WiFi deinitialized");
}

// ============================================================================
// Mode and Configuration
// ============================================================================

int wifi_helper_set_mode(int mode) {
    wifi_mode_t wifi_mode;
    switch (mode) {
        case WIFI_MODE_STA_VAL:
            wifi_mode = WIFI_MODE_STA;
            break;
        case WIFI_MODE_AP_VAL:
            wifi_mode = WIFI_MODE_AP;
            break;
        case WIFI_MODE_APSTA_VAL:
            wifi_mode = WIFI_MODE_APSTA;
            break;
        default:
            ESP_LOGE(TAG, "Invalid WiFi mode: %d", mode);
            return -1;
    }

    esp_err_t ret = esp_wifi_set_mode(wifi_mode);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_set_mode failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ESP_LOGI(TAG, "WiFi mode set to %d", mode);
    return 0;
}

int wifi_helper_set_sta_config(const char* ssid, const char* password) {
    wifi_config_t wifi_config = {
        .sta = {
            .threshold.authmode = WIFI_AUTH_WPA2_PSK,
            .sae_pwe_h2e = WPA3_SAE_PWE_BOTH,
        },
    };

    strncpy((char*)wifi_config.sta.ssid, ssid, sizeof(wifi_config.sta.ssid) - 1);
    strncpy((char*)wifi_config.sta.password, password, sizeof(wifi_config.sta.password) - 1);

    esp_err_t ret = esp_wifi_set_config(WIFI_IF_STA, &wifi_config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_set_config(STA) failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ESP_LOGI(TAG, "STA config set for SSID: %s", ssid);
    return 0;
}

int wifi_helper_set_ap_config(const char* ssid, const char* password, 
                               int channel, int max_conn) {
    wifi_config_t wifi_config = {
        .ap = {
            .channel = (uint8_t)channel,
            .max_connection = (uint8_t)max_conn,
            .authmode = WIFI_AUTH_WPA2_PSK,
            .pmf_cfg = {
                .required = false,
            },
        },
    };

    strncpy((char*)wifi_config.ap.ssid, ssid, sizeof(wifi_config.ap.ssid) - 1);
    wifi_config.ap.ssid_len = strlen(ssid);
    strncpy((char*)wifi_config.ap.password, password, sizeof(wifi_config.ap.password) - 1);

    // If no password, use open auth
    if (strlen(password) == 0) {
        wifi_config.ap.authmode = WIFI_AUTH_OPEN;
    }

    esp_err_t ret = esp_wifi_set_config(WIFI_IF_AP, &wifi_config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_set_config(AP) failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ESP_LOGI(TAG, "AP config set for SSID: %s, channel: %d", ssid, channel);
    return 0;
}

// ============================================================================
// Start / Stop
// ============================================================================

int wifi_helper_start(void) {
    if (s_started) {
        ESP_LOGD(TAG, "WiFi already started");
        return 0;
    }

    esp_err_t ret = esp_wifi_start();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_start failed: %s", esp_err_to_name(ret));
        return ret;
    }

    s_started = true;
    ESP_LOGI(TAG, "WiFi started");
    return 0;
}

void wifi_helper_stop(void) {
    if (!s_started) {
        return;
    }

    esp_wifi_stop();
    s_started = false;
    ESP_LOGI(TAG, "WiFi stopped");
}

// ============================================================================
// STA Operations
// ============================================================================

int wifi_helper_connect(uint32_t timeout_ms, int max_retry) {
    // Create event group for this connection attempt
    if (s_wifi_event_group == NULL) {
        s_wifi_event_group = xEventGroupCreate();
    }
    xEventGroupClearBits(s_wifi_event_group, WIFI_CONNECTED_BIT | WIFI_FAIL_BIT);

    s_retry_count = 0;
    s_max_retry = max_retry;

    // Register temporary event handlers
    esp_event_handler_instance_t wifi_handler;
    esp_event_handler_instance_t ip_handler;
    
    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                        &sta_event_handler, NULL, &wifi_handler);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                        &sta_event_handler, NULL, &ip_handler);

    // Start WiFi if not started
    if (!s_started) {
        esp_err_t ret = esp_wifi_start();
        if (ret != ESP_OK) {
            esp_event_handler_instance_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_handler);
            esp_event_handler_instance_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, ip_handler);
            return ret;
        }
        s_started = true;
    } else {
        // If already started, manually trigger connect
        esp_wifi_connect();
    }

    // Disable power save for faster connection
    esp_wifi_set_ps(WIFI_PS_NONE);

    // Wait for connection
    EventBits_t bits = xEventGroupWaitBits(s_wifi_event_group,
                                           WIFI_CONNECTED_BIT | WIFI_FAIL_BIT,
                                           pdFALSE, pdFALSE,
                                           pdMS_TO_TICKS(timeout_ms));

    // Unregister handlers
    esp_event_handler_instance_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_handler);
    esp_event_handler_instance_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, ip_handler);

    if (bits & WIFI_CONNECTED_BIT) {
        ESP_LOGI(TAG, "Connected to AP");
        return 0;
    } else if (bits & WIFI_FAIL_BIT) {
        ESP_LOGW(TAG, "Failed to connect after %d retries", s_max_retry);
        return -1;
    }

    ESP_LOGW(TAG, "Connection timeout");
    return -2;  // Timeout
}

void wifi_helper_disconnect(void) {
    esp_wifi_disconnect();
}

uint32_t wifi_helper_get_sta_ip(void) {
    esp_netif_t* netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (netif == NULL) {
        return 0;
    }

    esp_netif_ip_info_t ip_info;
    if (esp_netif_get_ip_info(netif, &ip_info) != ESP_OK) {
        return 0;
    }

    return ip_info.ip.addr;
}

int8_t wifi_helper_get_rssi(void) {
    wifi_ap_record_t ap_info;
    if (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK) {
        return ap_info.rssi;
    }
    return 0;
}

// ============================================================================
// Scan Operations
// ============================================================================

/// Flat struct for passing AP records to Zig (no alignment gaps)
typedef struct {
    uint8_t ssid[32];     // 0-31
    uint8_t ssid_len;     // 32
    uint8_t bssid[6];     // 33-38
    int8_t  rssi;         // 39
    uint8_t channel;      // 40
    uint8_t auth_mode;    // 41   mapped from wifi_auth_mode_t
    uint8_t _pad[2];      // 42-43
} wifi_helper_ap_flat_t;

/// Scan done event handler — sets flag for polling
static void scan_event_handler(void *arg, esp_event_base_t event_base,
                                int32_t event_id, void *event_data) {
    (void)arg;
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_SCAN_DONE) {
        wifi_event_sta_scan_done_t *ev = (wifi_event_sta_scan_done_t *)event_data;
        s_scan_success = (ev->status == 0);
        s_scan_done = true;
    }
}

/// Start a non-blocking WiFi scan.
/// WiFi must be started (wifi_helper_start) before calling this.
int wifi_helper_scan_start(int show_hidden, uint8_t channel) {
    // Register scan event handler once
    if (!s_scan_handler_registered) {
        esp_event_handler_instance_t instance;
        esp_err_t err = esp_event_handler_instance_register(
            WIFI_EVENT, WIFI_EVENT_SCAN_DONE,
            &scan_event_handler, NULL, &instance);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Failed to register scan handler: %s", esp_err_to_name(err));
            return err;
        }
        s_scan_handler_registered = true;
    }

    s_scan_done = false;
    s_scan_success = false;

    // Ensure WiFi is started (required before scanning)
    if (!s_started) {
        esp_err_t start_ret = esp_wifi_start();
        if (start_ret != ESP_OK) {
            ESP_LOGE(TAG, "esp_wifi_start failed: %s", esp_err_to_name(start_ret));
            return start_ret;
        }
        s_started = true;
        // Disable power save for scan
        esp_wifi_set_ps(WIFI_PS_NONE);
    }

    wifi_scan_config_t cfg = {
        .ssid = NULL,
        .bssid = NULL,
        .channel = channel,
        .show_hidden = show_hidden ? true : false,
        .scan_type = WIFI_SCAN_TYPE_ACTIVE,
        .scan_time = {
            .active = { .min = 0, .max = 0 },  // use defaults
        },
    };
    esp_err_t ret = esp_wifi_scan_start(&cfg, false /* non-blocking */);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_scan_start failed: %s", esp_err_to_name(ret));
        return ret;
    }
    return 0;
}

/// Poll whether scan is done. Returns 1 if done, 0 if still scanning.
/// Atomically clears the flag on read.
int wifi_helper_scan_poll_done(int *out_success) {
    if (s_scan_done) {
        s_scan_done = false;
        *out_success = s_scan_success ? 1 : 0;
        return 1;
    }
    return 0;
}

/// Map ESP-IDF wifi_auth_mode_t to our simplified AuthMode ordinal.
/// Matches the enum order: open=0, wep=1, wpa_psk=2, wpa2_psk=3, ...
static uint8_t map_auth_mode(wifi_auth_mode_t mode) {
    switch (mode) {
        case WIFI_AUTH_OPEN:            return 0;
        case WIFI_AUTH_WEP:             return 1;
        case WIFI_AUTH_WPA_PSK:         return 2;
        case WIFI_AUTH_WPA2_PSK:        return 3;
        case WIFI_AUTH_WPA_WPA2_PSK:    return 4;
        case WIFI_AUTH_WPA3_PSK:        return 5;
        case WIFI_AUTH_WPA2_WPA3_PSK:   return 6;
        case WIFI_AUTH_WPA2_ENTERPRISE: return 7;
        case WIFI_AUTH_WPA3_ENTERPRISE: return 8;
        default:                        return 0;
    }
}

/// Fetch AP records into flat structs.
/// Caller provides buffer; count is in/out (in: buffer capacity, out: actual).
int wifi_helper_scan_get_ap_records(wifi_helper_ap_flat_t *out, uint16_t *inout_count) {
    uint16_t cap = *inout_count;
    if (cap == 0) return 0;

    wifi_ap_record_t *records = malloc(cap * sizeof(wifi_ap_record_t));
    if (records == NULL) {
        *inout_count = 0;
        return -1;
    }

    esp_err_t ret = esp_wifi_scan_get_ap_records(&cap, records);
    if (ret != ESP_OK) {
        free(records);
        *inout_count = 0;
        return ret;
    }

    for (uint16_t i = 0; i < cap; i++) {
        memset(&out[i], 0, sizeof(wifi_helper_ap_flat_t));
        size_t ssid_len = strlen((const char *)records[i].ssid);
        if (ssid_len > 32) ssid_len = 32;
        memcpy(out[i].ssid, records[i].ssid, ssid_len);
        out[i].ssid_len = (uint8_t)ssid_len;
        memcpy(out[i].bssid, records[i].bssid, 6);
        out[i].rssi = records[i].rssi;
        out[i].channel = records[i].primary;
        out[i].auth_mode = map_auth_mode(records[i].authmode);
    }

    *inout_count = cap;
    free(records);
    return 0;
}

// ============================================================================
// AP Operations
// ============================================================================

int wifi_helper_get_ap_station_count(void) {
    wifi_sta_list_t sta_list;
    if (esp_wifi_ap_get_sta_list(&sta_list) != ESP_OK) {
        return 0;
    }
    return sta_list.num;
}

int wifi_helper_get_ap_stations(uint8_t* mac_list, int max_count) {
    wifi_sta_list_t sta_list;
    if (esp_wifi_ap_get_sta_list(&sta_list) != ESP_OK) {
        return 0;
    }

    int count = (sta_list.num < max_count) ? sta_list.num : max_count;
    for (int i = 0; i < count; i++) {
        memcpy(&mac_list[i * 6], sta_list.sta[i].mac, 6);
    }

    return count;
}

// ============================================================================
// Legacy API (for backward compatibility)
// ============================================================================

// Legacy init - does everything (for old code)
int wifi_helper_legacy_init(void) {
    ESP_LOGW(TAG, "Using legacy init - consider using new modular API");
    
    if (s_wifi_event_group == NULL) {
        s_wifi_event_group = xEventGroupCreate();
    }

    // Note: netif and event loop should be initialized by caller now
    // This is kept for backward compatibility

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t ret = esp_wifi_init(&cfg);
    if (ret != ESP_OK) return ret;

    s_initialized = true;
    return 0;
}

// Legacy connect - combines set_mode, set_sta_config, start, connect
int wifi_helper_legacy_connect(const char *ssid, const char *password, uint32_t timeout_ms) {
    int ret = wifi_helper_set_mode(WIFI_MODE_STA_VAL);
    if (ret != 0) return ret;

    ret = wifi_helper_set_sta_config(ssid, password);
    if (ret != 0) return ret;

    return wifi_helper_connect(timeout_ms, 5);
}

// Legacy get_ip - same as get_sta_ip
uint32_t wifi_helper_get_ip(void) {
    return wifi_helper_get_sta_ip();
}
