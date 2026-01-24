// WiFi helper functions for Zig
// Handles complex ESP-IDF structures that @cImport cannot translate

#include <string.h>
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_log.h"

static const char *TAG = "wifi_helper";

// WiFi state
static volatile uint8_t g_wifi_state = 0; // 0=disconnected, 1=connecting, 2=connected, 3=got_ip
static uint32_t g_ip_addr = 0;

// Event handlers
static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data) {
    if (event_base == WIFI_EVENT) {
        if (event_id == WIFI_EVENT_STA_START) {
            esp_wifi_connect();
            g_wifi_state = 1; // connecting
        } else if (event_id == WIFI_EVENT_STA_DISCONNECTED) {
            g_wifi_state = 0; // disconnected
            esp_wifi_connect(); // auto-reconnect
            g_wifi_state = 1; // connecting
        } else if (event_id == WIFI_EVENT_STA_CONNECTED) {
            g_wifi_state = 2; // connected
        }
    } else if (event_base == IP_EVENT) {
        if (event_id == IP_EVENT_STA_GOT_IP) {
            ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
            g_ip_addr = event->ip_info.ip.addr;
            g_wifi_state = 3; // got_ip
            ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&event->ip_info.ip));
        }
    }
}

// Initialize WiFi subsystem
int wifi_helper_init(void) {
    // Initialize TCP/IP stack
    esp_err_t ret = esp_netif_init();
    if (ret != ESP_OK) return ret;

    // Create default event loop
    ret = esp_event_loop_create_default();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) return ret;

    // Create default WiFi station
    esp_netif_create_default_wifi_sta();

    // Initialize WiFi with default config
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ret = esp_wifi_init(&cfg);
    if (ret != ESP_OK) return ret;

    // Register event handlers
    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                        &wifi_event_handler, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                        &wifi_event_handler, NULL, NULL);

    return ESP_OK;
}

// Connect to WiFi
int wifi_helper_connect(const char *ssid, const char *password) {
    wifi_config_t wifi_config = {
        .sta = {
            .threshold.authmode = WIFI_AUTH_WPA2_PSK,
            .sae_pwe_h2e = WPA3_SAE_PWE_BOTH,
        },
    };
    
    strncpy((char *)wifi_config.sta.ssid, ssid, sizeof(wifi_config.sta.ssid) - 1);
    strncpy((char *)wifi_config.sta.password, password, sizeof(wifi_config.sta.password) - 1);

    esp_err_t ret = esp_wifi_set_mode(WIFI_MODE_STA);
    if (ret != ESP_OK) return ret;

    ret = esp_wifi_set_config(WIFI_IF_STA, &wifi_config);
    if (ret != ESP_OK) return ret;

    g_wifi_state = 1; // connecting
    ret = esp_wifi_start();
    if (ret != ESP_OK) return ret;

    return ESP_OK;
}

// Get current state
uint8_t wifi_helper_get_state(void) {
    return g_wifi_state;
}

// Get IP address
void wifi_helper_get_ip(uint8_t *ip_out) {
    ip_out[0] = g_ip_addr & 0xFF;
    ip_out[1] = (g_ip_addr >> 8) & 0xFF;
    ip_out[2] = (g_ip_addr >> 16) & 0xFF;
    ip_out[3] = (g_ip_addr >> 24) & 0xFF;
}

// Disconnect
void wifi_helper_disconnect(void) {
    esp_wifi_disconnect();
    g_wifi_state = 0;
}
