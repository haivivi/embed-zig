/**
 * Timer helper functions for Zig
 * Wraps complex ESP-IDF structures that are difficult for @cImport
 */

#include "driver/gptimer.h"
#include "esp_err.h"

/**
 * Create a new timer with simple configuration
 */
esp_err_t gptimer_new_timer_simple(uint32_t resolution_hz, gptimer_handle_t *out_handle)
{
    gptimer_config_t config = {
        .clk_src = GPTIMER_CLK_SRC_DEFAULT,
        .direction = GPTIMER_COUNT_UP,
        .resolution_hz = resolution_hz,
        .intr_priority = 0,
    };
    return gptimer_new_timer(&config, out_handle);
}

/**
 * Set alarm with simple configuration
 */
esp_err_t gptimer_set_alarm_simple(gptimer_handle_t timer, uint64_t alarm_count, int auto_reload)
{
    gptimer_alarm_config_t alarm_config = {
        .alarm_count = alarm_count,
        .reload_count = 0,
        .flags.auto_reload_on_alarm = auto_reload ? 1 : 0,
    };
    return gptimer_set_alarm_action(timer, &alarm_config);
}

/**
 * Register callback with simple configuration
 */
esp_err_t gptimer_register_callback_simple(gptimer_handle_t timer, 
                                           gptimer_alarm_cb_t callback,
                                           void *user_data)
{
    gptimer_event_callbacks_t cbs = {
        .on_alarm = callback,
    };
    return gptimer_register_event_callbacks(timer, &cbs, user_data);
}
