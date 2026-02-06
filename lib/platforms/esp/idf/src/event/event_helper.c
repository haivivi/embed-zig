/**
 * Event Loop Helper Implementation
 *
 * Wraps ESP-IDF default event loop with idempotent init/deinit.
 */

#include "event_helper.h"
#include "esp_event.h"
#include "esp_log.h"

static const char* TAG = "event_helper";
static bool s_initialized = false;

int event_helper_init(void) {
    if (s_initialized) {
        ESP_LOGD(TAG, "Event loop already initialized");
        return 0;
    }

    esp_err_t ret = esp_event_loop_create_default();
    if (ret == ESP_OK) {
        s_initialized = true;
        ESP_LOGI(TAG, "Default event loop created");
        return 0;
    } else if (ret == ESP_ERR_INVALID_STATE) {
        // Already created by someone else
        s_initialized = true;
        ESP_LOGD(TAG, "Event loop was already created");
        return 0;
    }

    ESP_LOGE(TAG, "Failed to create event loop: %s", esp_err_to_name(ret));
    return -1;
}

void event_helper_deinit(void) {
    if (!s_initialized) {
        return;
    }

    esp_err_t ret = esp_event_loop_delete_default();
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to delete event loop: %s", esp_err_to_name(ret));
    }
    s_initialized = false;
}

bool event_helper_is_initialized(void) {
    return s_initialized;
}
