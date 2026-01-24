/**
 * LED Strip Flash Example - C Version
 * 
 * This is a C implementation of the same LED strip blinking
 * functionality as the Zig version, for comparison purposes.
 */

#include <stdio.h>
#include "sdkconfig.h"
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "led_strip.h"

static const char *TAG = "led_strip";
static const char *BUILD_TAG = "led_strip_c_v1";

static led_strip_handle_t led_strip;
static bool led_state = false;

static esp_err_t led_strip_init(void)
{
    led_strip_config_t strip_config = {
        .strip_gpio_num = CONFIG_BLINK_GPIO,
        .max_leds = 1,
    };

    led_strip_rmt_config_t rmt_config = {
        .resolution_hz = 10 * 1000 * 1000,
    };

    ESP_ERROR_CHECK(led_strip_new_rmt_device(&strip_config, &rmt_config, &led_strip));
    ESP_ERROR_CHECK(led_strip_clear(led_strip));

    return ESP_OK;
}

static void led_strip_toggle(void)
{
    if (led_state) {
        led_strip_clear(led_strip);
    } else {
        led_strip_set_pixel(led_strip, 0, 16, 16, 16);
        led_strip_refresh(led_strip);
    }
    led_state = !led_state;
}

static void print_memory_stats(void)
{
    ESP_LOGI(TAG, "=== Heap Memory Statistics ===");
    
    size_t internal_total = heap_caps_get_total_size(MALLOC_CAP_INTERNAL);
    size_t internal_free = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    size_t internal_used = internal_total - internal_free;
    size_t internal_min_free = heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL);
    size_t internal_largest = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);

    ESP_LOGI(TAG, "Internal DRAM:");
    ESP_LOGI(TAG, "  Total: %u bytes", (unsigned int)internal_total);
    ESP_LOGI(TAG, "  Free:  %u bytes", (unsigned int)internal_free);
    ESP_LOGI(TAG, "  Used:  %u bytes", (unsigned int)internal_used);
    ESP_LOGI(TAG, "  Min free: %u bytes", (unsigned int)internal_min_free);
    ESP_LOGI(TAG, "  Largest: %u bytes", (unsigned int)internal_largest);

    size_t psram_total = heap_caps_get_total_size(MALLOC_CAP_SPIRAM);
    if (psram_total > 0) {
        size_t psram_free = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
        size_t psram_used = psram_total - psram_free;
        size_t psram_min_free = heap_caps_get_minimum_free_size(MALLOC_CAP_SPIRAM);
        size_t psram_largest = heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);

        ESP_LOGI(TAG, "External PSRAM:");
        ESP_LOGI(TAG, "  Total: %u bytes", (unsigned int)psram_total);
        ESP_LOGI(TAG, "  Free:  %u bytes", (unsigned int)psram_free);
        ESP_LOGI(TAG, "  Used:  %u bytes", (unsigned int)psram_used);
        ESP_LOGI(TAG, "  Min free: %u bytes", (unsigned int)psram_min_free);
        ESP_LOGI(TAG, "  Largest: %u bytes", (unsigned int)psram_largest);
    } else {
        ESP_LOGI(TAG, "External PSRAM: not available");
    }

    size_t dma_free = heap_caps_get_free_size(MALLOC_CAP_DMA);
    ESP_LOGI(TAG, "DMA capable free: %u bytes", (unsigned int)dma_free);
}

void app_main(void)
{
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "  LED Strip Flash - C Version");
    ESP_LOGI(TAG, "  Build Tag: %s", BUILD_TAG);
    ESP_LOGI(TAG, "==========================================");
    
    print_memory_stats();
    
    ESP_ERROR_CHECK(led_strip_init());

    while (1) {
        ESP_LOGI(TAG, "Toggling the LED %s!", led_state ? "ON" : "OFF");
        led_strip_toggle();
        vTaskDelay(CONFIG_BLINK_PERIOD / portTICK_PERIOD_MS);
    }
}
