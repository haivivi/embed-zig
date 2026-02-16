/**
 * bk_zig_temp_helper.c — Internal temperature sensor
 *
 * Wraps bk_sensor_get_current_temperature() for Zig FFI.
 * Returns temperature as integer (x100) to avoid float ABI issues.
 *
 * On BK7258, the temp sensor implementation lives in the CP core
 * (cp/components/temp_detect/bk_sensor.c). The AP declares the symbol
 * in sensor.h but doesn't link the implementation. We provide a weak
 * fallback so the build always succeeds; at runtime the CP's strong
 * symbol wins if temp_detect is enabled.
 */

#include <components/sensor.h>
#include <components/log.h>

/* Weak fallback — used when CP's temp_detect is not linked on AP side */
__attribute__((weak))
bk_err_t bk_sensor_get_current_temperature(float *temperature) {
    (void)temperature;
    return BK_ERR_NOT_INIT;  /* sensor not available on this core */
}

/**
 * Read MCU internal temperature.
 * @param temp_x100_out  Temperature * 100 (e.g., 3250 = 32.50°C)
 * @return 0 on success
 */
int bk_zig_temp_read(int *temp_x100_out) {
    float temp = 0.0f;
    int ret = bk_sensor_get_current_temperature(&temp);
    if (ret != 0) return ret;
    *temp_x100_out = (int)(temp * 100.0f);
    return 0;
}
