/**
 * HTTP Speed Test - C Version
 * 
 * Tests HTTP download speed using esp_http_client
 * Runs on PSRAM task stack for fair comparison with Zig versions
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "freertos/idf_additions.h"
#include "esp_system.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "nvs_flash.h"
#include "esp_http_client.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_crt_bundle.h"
#include "sdkconfig.h"

// HTTPS test URL - Tsinghua Mirror Python 3.12 (27MB)
#define HTTPS_TEST_URL "https://mirrors.tuna.tsinghua.edu.cn/python/3.12.0/Python-3.12.0.tgz"

static const char *TAG = "http_speed";
static const char *BUILD_TAG = "https_speed_c_v1";

// WiFi event group
static EventGroupHandle_t s_wifi_event_group;
#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAIL_BIT      BIT1

static int s_retry_num = 0;
#define MAX_RETRY 5

// ============================================================================
// Memory Statistics
// ============================================================================

static void print_memory_stats(void) {
    ESP_LOGI(TAG, "=== Heap Memory Statistics ===");
    
    // Internal DRAM
    size_t internal_total = heap_caps_get_total_size(MALLOC_CAP_INTERNAL);
    size_t internal_free = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    ESP_LOGI(TAG, "Internal DRAM: Total=%u Free=%u Used=%u",
             internal_total, internal_free, internal_total - internal_free);
    
    // External PSRAM
    size_t psram_total = heap_caps_get_total_size(MALLOC_CAP_SPIRAM);
    size_t psram_free = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    if (psram_total > 0) {
        ESP_LOGI(TAG, "External PSRAM: Total=%u Free=%u Used=%u",
                 psram_total, psram_free, psram_total - psram_free);
    }
}

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
            ESP_LOGI(TAG, "Retry connecting to WiFi... (%d/%d)", s_retry_num, MAX_RETRY);
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
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT,
                                                        ESP_EVENT_ANY_ID,
                                                        &event_handler,
                                                        NULL,
                                                        &instance_any_id));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT,
                                                        IP_EVENT_STA_GOT_IP,
                                                        &event_handler,
                                                        NULL,
                                                        &instance_got_ip));

    wifi_config_t wifi_config = {
        .sta = {
            .ssid = CONFIG_WIFI_SSID,
            .password = CONFIG_WIFI_PASSWORD,
            .threshold.authmode = WIFI_AUTH_WPA2_PSK,
        },
    };
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());
    
    // Disable WiFi power save for maximum throughput
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
    ESP_LOGI(TAG, "WiFi power save disabled for max speed");

    ESP_LOGI(TAG, "Connecting to SSID: %s", CONFIG_WIFI_SSID);

    // Wait for connection
    EventBits_t bits = xEventGroupWaitBits(s_wifi_event_group,
            WIFI_CONNECTED_BIT | WIFI_FAIL_BIT,
            pdFALSE, pdFALSE, pdMS_TO_TICKS(30000));

    if (bits & WIFI_CONNECTED_BIT) {
        return ESP_OK;
    } else if (bits & WIFI_FAIL_BIT) {
        ESP_LOGE(TAG, "Failed to connect to WiFi");
        return ESP_FAIL;
    } else {
        ESP_LOGE(TAG, "WiFi connection timeout");
        return ESP_ERR_TIMEOUT;
    }
}

// ============================================================================
// HTTP Speed Test
// ============================================================================

typedef struct {
    size_t total_bytes;
    size_t last_print_bytes;
    int64_t start_time;
} http_download_ctx_t;

static esp_err_t http_event_handler(esp_http_client_event_t *evt)
{
    http_download_ctx_t *ctx = (http_download_ctx_t *)evt->user_data;
    
    switch(evt->event_id) {
        case HTTP_EVENT_ON_DATA:
            ctx->total_bytes += evt->data_len;
            // Print progress every 1MB with memory stats
            if (ctx->total_bytes - ctx->last_print_bytes >= 1024 * 1024) {
                int64_t now = esp_timer_get_time();
                double elapsed = (now - ctx->start_time) / 1000000.0;
                double speed = (ctx->total_bytes / 1024.0) / elapsed;
                size_t iram_free = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
                size_t psram_free = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
                // Get WiFi RSSI
                wifi_ap_record_t ap_info;
                int8_t rssi = 0;
                if (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK) {
                    rssi = ap_info.rssi;
                }
                ESP_LOGI("http", "Progress: %u bytes (%.0f KB/s) | RSSI: %d | IRAM: %u, PSRAM: %u free", 
                         ctx->total_bytes, speed, rssi, iram_free, psram_free);
                ctx->last_print_bytes = ctx->total_bytes;
            }
            break;
        default:
            break;
    }
    return ESP_OK;
}

static void run_speed_test(const char *url, const char *test_name, bool is_https)
{
    ESP_LOGI(TAG, "--- %s ---", test_name);
    ESP_LOGI(TAG, "URL: %s", url);
    
    http_download_ctx_t ctx = {
        .total_bytes = 0,
        .last_print_bytes = 0,
        .start_time = esp_timer_get_time(),
    };
    
    esp_http_client_config_t config = {
        .url = url,
        .event_handler = http_event_handler,
        .user_data = &ctx,
        .buffer_size = 16384,       // 16KB receive buffer
        .buffer_size_tx = 4096,     // 4KB send buffer
        .timeout_ms = 120000,       // 2 minutes timeout for large files
        .crt_bundle_attach = is_https ? esp_crt_bundle_attach : NULL,
    };
    
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (!client) {
        ESP_LOGE(TAG, "Failed to init HTTP client");
        return;
    }
    
    // Record memory before
    size_t mem_before = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    
    int64_t start_time = esp_timer_get_time();
    esp_err_t err = esp_http_client_perform(client);
    int64_t end_time = esp_timer_get_time();
    
    // Record memory after
    size_t mem_after = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    
    if (err == ESP_OK) {
        int status = esp_http_client_get_status_code(client);
        int64_t content_length = esp_http_client_get_content_length(client);
        int64_t duration_us = end_time - start_time;
        double duration_sec = duration_us / 1000000.0;
        double speed_kbps = (ctx.total_bytes / 1024.0) / duration_sec;
        double speed_mbps = speed_kbps / 1024.0;
        
        ESP_LOGI(TAG, "Status: %d, Content-Length: %lld", status, content_length);
        ESP_LOGI(TAG, "Downloaded: %u bytes in %.2f sec", ctx.total_bytes, duration_sec);
        ESP_LOGI(TAG, "Speed: %.2f KB/s (%.3f MB/s)", speed_kbps, speed_mbps);
        ESP_LOGI(TAG, "Memory used during download: %d bytes", (int)(mem_before - mem_after));
    } else {
        ESP_LOGE(TAG, "HTTP request failed: %s", esp_err_to_name(err));
    }
    
    esp_http_client_cleanup(client);
}

static void http_speed_test_task(void *pvParameters)
{
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "=== HTTPS Speed Test (C esp_http_client) ===");
    ESP_LOGI(TAG, "Note: Running on PSRAM stack task (64KB)");
    ESP_LOGI(TAG, "Note: Using ESP-IDF CA certificate bundle");
    
    // Test HTTPS download - Tsinghua Mirror Python 3.12 (27MB)
    run_speed_test(HTTPS_TEST_URL, "HTTPS Download 27MB (Tsinghua Mirror)", true);
    
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "=== HTTPS Speed Test Complete ===");
    print_memory_stats();
    
    // Log stack usage (high water mark = minimum free stack ever, in words)
    UBaseType_t high_water_mark = uxTaskGetStackHighWaterMark(NULL);
    uint32_t min_free_bytes = high_water_mark * sizeof(StackType_t);
    uint32_t stack_size = 65536;  // Must match create_psram_task call
    uint32_t max_used_bytes = stack_size - min_free_bytes;
    ESP_LOGI(TAG, "task 'http_test' exit, stack used: %lu/%lu bytes (free: %lu)", 
             (unsigned long)max_used_bytes, (unsigned long)stack_size, (unsigned long)min_free_bytes);
    
    // Signal completion and delete task
    vTaskDelete(NULL);
}

// Create task with PSRAM stack
static esp_err_t create_psram_task(const char *name, TaskFunction_t func, 
                                    uint32_t stack_size, UBaseType_t priority)
{
    // Allocate stack from PSRAM
    StackType_t *stack = heap_caps_malloc(stack_size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (stack == NULL) {
        ESP_LOGE(TAG, "Failed to allocate PSRAM stack");
        return ESP_ERR_NO_MEM;
    }
    
    // Create task with custom stack
    TaskParameters_t task_params = {
        .pvTaskCode = func,
        .pcName = name,
        .usStackDepth = stack_size / sizeof(StackType_t),
        .pvParameters = NULL,
        .uxPriority = priority,
        .puxStackBuffer = stack,
        .xRegions = {{0}}
    };
    
    TaskHandle_t handle = NULL;
    BaseType_t result = xTaskCreateRestrictedPinnedToCore(&task_params, &handle, 1);
    
    if (result != pdPASS) {
        ESP_LOGE(TAG, "Failed to create PSRAM task");
        heap_caps_free(stack);
        return ESP_FAIL;
    }
    
    ESP_LOGI(TAG, "Created task '%s' with %" PRIu32 " bytes PSRAM stack", name, stack_size);
    return ESP_OK;
}

// ============================================================================
// Main
// ============================================================================

void app_main(void)
{
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "  HTTP Speed Test - C esp_http_client");
    ESP_LOGI(TAG, "  Build Tag: %s", BUILD_TAG);
    ESP_LOGI(TAG, "==========================================");
    
    print_memory_stats();
    
    // Initialize NVS
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);
    
    // Connect to WiFi
    if (wifi_init_sta() != ESP_OK) {
        ESP_LOGE(TAG, "WiFi connection failed. Halting.");
        while (1) {
            vTaskDelay(pdMS_TO_TICKS(1000));
        }
    }
    
    print_memory_stats();
    
    // Run speed test on PSRAM stack task (64KB)
    ESP_LOGI(TAG, "Starting HTTP test on PSRAM stack task (64KB stack)...");
    ret = create_psram_task("http_test", http_speed_test_task, 65536, 16);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create HTTP test task");
        return;
    }
    
    // Keep main task running
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(10000));
        ESP_LOGI(TAG, "Still running...");
    }
}
