/**
 * esp_timer helper for Zig
 * Wraps esp_timer_create which requires designated initializer struct
 */

#include "esp_timer_helper.h"

esp_err_t esp_timer_create_oneshot(esp_timer_zig_cb_t callback, void* arg,
                                   esp_timer_handle_t* out_handle)
{
    esp_timer_create_args_t args = {
        .callback = callback,
        .arg = arg,
        .dispatch_method = ESP_TIMER_TASK,
        .name = "zig_timer",
        .skip_unhandled_events = false,
    };
    return esp_timer_create(&args, out_handle);
}
