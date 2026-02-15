/**
 * bk_zig_temp_helper.c — Internal temperature sensor
 *
 * Wraps bk_sensor_get_current_temperature() for Zig FFI.
 * Returns temperature as integer (x100) to avoid float ABI issues.
 */

#include <components/sensor.h>
#include <components/log.h>

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
