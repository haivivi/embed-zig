/**
 * HTTP Speed Test - C Version
 * Tests HTTP download speed using esp_http_client
 */

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_system.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "nvs_flash.h"
#include "esp_http_client.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "sdkconfig.h"

static const char *TAG = "http_speed";

// WiFi event group
static EventGroupHandle_t s_wifi_event_group;
#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAIL_BIT      BIT1

static int s_retry_num = 0;
#define MAX_RETRY 5

// HTTP test URLs (local server)
#define HTTP_URL_10M "http://" CONFIG_TEST_SERVER_IP ":" CONFIG_TEST_SERVER_PORT_STR "/test/10m"
#define HTTP_URL_50M "http://" CONFIG_TEST_SERVER_IP ":" CONFIG_TEST_SERVER_PORT_STR "/test/52428800"

// ============================================================================
// WiFi
// ============================================================================

static void event_handler(void* arg, esp_event_base_t event_base,
                          int32_t event_id, void* event_data)
{
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        if (s_retry_num < MAX_RETRY) {
            esp_wifi_connect();
            s_retry_num++;
            ESP_LOGI(TAG, "Retry connecting... (%d/%d)", s_retry_num, MAX_RETRY);
        } else {
            xEventGroupSetBits(s_wifi_event_group, WIFI_FAIL_BIT);
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* event = (ip_event_got_ip_t*) event_data;
        ESP_LOGI(TAG, "Connected! IP: " IPSTR, IP2STR(&event->ip_info.ip));
        s_retry_num = 0;
        xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
    }
}

static esp_err_t wifi_init_sta(void)
{
    s_wifi_event_group = xEventGroupCreate();

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    esp_event_handler_instance_t instance_any_id;
    esp_event_handler_instance_t instance_got_ip;
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                        &event_handler, NULL, &instance_any_id));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                        &event_handler, NULL, &instance_got_ip));

    wifi_config_t wifi_config = {
        .sta = {
            .ssid = CONFIG_WIFI_SSID,
            .password = CONFIG_WIFI_PASSWORD,
        },
    };
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

    EventBits_t bits = xEventGroupWaitBits(s_wifi_event_group,
            WIFI_CONNECTED_BIT | WIFI_FAIL_BIT, pdFALSE, pdFALSE, pdMS_TO_TICKS(30000));

    if (bits & WIFI_CONNECTED_BIT) {
        return ESP_OK;
    }
    return ESP_FAIL;
}

// ============================================================================
// HTTP Speed Test
// ============================================================================

typedef struct {
    size_t total_bytes;
    size_t last_print_bytes;
    int64_t start_time;
} http_ctx_t;

static esp_err_t http_event_handler(esp_http_client_event_t *evt)
{
    http_ctx_t *ctx = (http_ctx_t *)evt->user_data;
    
    if (evt->event_id == HTTP_EVENT_ON_DATA) {
        ctx->total_bytes += evt->data_len;
        if (ctx->total_bytes - ctx->last_print_bytes >= 1024 * 1024) {
            int64_t now = esp_timer_get_time();
            double elapsed = (now - ctx->start_time) / 1000000.0;
            double speed = (ctx->total_bytes / 1024.0) / elapsed;
            ESP_LOGI("http", "Progress: %u bytes (%.0f KB/s)", ctx->total_bytes, speed);
            ctx->last_print_bytes = ctx->total_bytes;
        }
    }
    return ESP_OK;
}

static void run_http_test(const char *url, const char *test_name)
{
    ESP_LOGI(TAG, "--- %s ---", test_name);
    
    http_ctx_t ctx = {
        .total_bytes = 0,
        .last_print_bytes = 0,
        .start_time = esp_timer_get_time(),
    };
    
    esp_http_client_config_t config = {
        .url = url,
        .event_handler = http_event_handler,
        .user_data = &ctx,
        .buffer_size = 16384,
        .timeout_ms = 120000,
    };
    
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (!client) {
        ESP_LOGE(TAG, "Failed to init HTTP client");
        return;
    }
    
    int64_t start = esp_timer_get_time();
    esp_err_t err = esp_http_client_perform(client);
    int64_t end = esp_timer_get_time();
    
    if (err == ESP_OK) {
        double duration = (end - start) / 1000000.0;
        double speed = (ctx.total_bytes / 1024.0) / duration;
        ESP_LOGI(TAG, "Downloaded: %u bytes in %.2f sec", ctx.total_bytes, duration);
        ESP_LOGI(TAG, "Speed: %.0f KB/s", speed);
    } else {
        ESP_LOGE(TAG, "HTTP request failed: %s", esp_err_to_name(err));
    }
    
    esp_http_client_cleanup(client);
}

// ============================================================================
// Main
// ============================================================================

void app_main(void)
{
    ESP_LOGI(TAG, "=== HTTP Speed Test (C) ===");
    ESP_LOGI(TAG, "Server: %s:%s", CONFIG_TEST_SERVER_IP, CONFIG_TEST_SERVER_PORT_STR);
    
    // Initialize NVS
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);
    
    // Connect WiFi
    if (wifi_init_sta() != ESP_OK) {
        ESP_LOGE(TAG, "WiFi failed");
        return;
    }
    
    vTaskDelay(pdMS_TO_TICKS(1000));
    
    // Run tests
    run_http_test(HTTP_URL_10M, "HTTP Download 10MB");
    vTaskDelay(pdMS_TO_TICKS(1000));
    run_http_test(HTTP_URL_50M, "HTTP Download 50MB");
    
    ESP_LOGI(TAG, "=== Test Complete ===");
}
