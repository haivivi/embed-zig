/**
 * bk_zig_gpio_helper.c — GPIO helpers for Zig.
 */
#include <driver/gpio.h>

int bk_zig_gpio_enable_output(unsigned int id) {
    return bk_gpio_enable_output((gpio_id_t)id);
}

int bk_zig_gpio_enable_input(unsigned int id) {
    return bk_gpio_enable_input((gpio_id_t)id);
}

void bk_zig_gpio_set_output(unsigned int id, int high) {
    bk_gpio_set_output_value((gpio_id_t)id, high ? true : false);
}

int bk_zig_gpio_get_input(unsigned int id) {
    return bk_gpio_get_input((gpio_id_t)id) ? 1 : 0;
}

int bk_zig_gpio_pull_up(unsigned int id) {
    bk_gpio_enable_pull((gpio_id_t)id);
    return bk_gpio_pull_up((gpio_id_t)id);
}

int bk_zig_gpio_pull_down(unsigned int id) {
    bk_gpio_enable_pull((gpio_id_t)id);
    return bk_gpio_pull_down((gpio_id_t)id);
}
