/**
 * bk_zig_gpio_helper.c — GPIO helpers for Zig.
 */
#include <stdio.h>
#include <driver/gpio.h>
#include <driver/hal/hal_gpio_types.h>
#include <components/log.h>

#define TAG "zig_gpio"

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

/* Unmap second function (QSPI etc.), configure as input + pull-up.
 * Uses gpio_dev_unmap() which is the correct way to release
 * GPIO from peripheral functions (same as key_main.c key_gpio_config). */
extern void gpio_dev_unmap(unsigned int id);

int bk_zig_gpio_set_as_input_pullup(unsigned int id) {
    gpio_dev_unmap(id);
    bk_gpio_disable_output((gpio_id_t)id);
    bk_gpio_enable_input((gpio_id_t)id);
    bk_gpio_enable_pull((gpio_id_t)id);
    return bk_gpio_pull_up((gpio_id_t)id);
}

int bk_zig_gpio_set_as_input_pulldown(unsigned int id) {
    gpio_dev_unmap(id);
    bk_gpio_disable_output((gpio_id_t)id);
    bk_gpio_enable_input((gpio_id_t)id);
    bk_gpio_enable_pull((gpio_id_t)id);
    return bk_gpio_pull_down((gpio_id_t)id);
}

int bk_zig_gpio_set_as_output(unsigned int id) {
    gpio_dev_unmap(id);
    bk_gpio_disable_input((gpio_id_t)id);
    return bk_gpio_enable_output((gpio_id_t)id);
}

/* Full GPIO scan: unmap + read every GPIO, print only LOW ones */
void bk_zig_gpio_full_scan(void) {
    char buf[256];
    int pos = 0;
    for (int i = 0; i < 56; i++) {
        if (i == 10 || i == 11) continue; /* UART */
        gpio_dev_unmap(i);
        bk_gpio_disable_output((gpio_id_t)i);
        bk_gpio_enable_input((gpio_id_t)i);
        bk_gpio_enable_pull((gpio_id_t)i);
        bk_gpio_pull_up((gpio_id_t)i);
    }
    /* settle */
    for (volatile int d = 0; d < 10000; d++) {}
    for (int i = 0; i < 56; i++) {
        if (i == 10 || i == 11) continue;
        if (!bk_gpio_get_input((gpio_id_t)i)) {
            pos += snprintf(buf + pos, sizeof(buf) - pos, " %d", i);
        }
    }
    if (pos > 0)
        BK_LOGI(TAG, "LOW:%s\r\n", buf);
    else
        BK_LOGI(TAG, "LOW: (none)\r\n");
}

int bk_zig_gpio_pull_down(unsigned int id) {
    bk_gpio_enable_pull((gpio_id_t)id);
    return bk_gpio_pull_down((gpio_id_t)id);
}
