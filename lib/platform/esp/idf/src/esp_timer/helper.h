/**
 * esp_timer helper for Zig
 * Wraps esp_timer_create which uses designated initializers
 */

#ifndef ESP_TIMER_HELPER_H
#define ESP_TIMER_HELPER_H

#include "esp_timer.h"
#include "esp_err.h"

typedef void (*esp_timer_zig_cb_t)(void* arg);

esp_err_t esp_timer_create_oneshot(esp_timer_zig_cb_t callback, void* arg,
                                   esp_timer_handle_t* out_handle);

#endif
