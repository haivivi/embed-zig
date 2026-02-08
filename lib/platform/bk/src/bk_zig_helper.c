/**
 * bk_zig_helper.c — Thin C helpers for Zig ↔ Armino interop.
 *
 * BK_LOGI is a variadic C macro that Zig can't call directly.
 * These helpers provide simple non-variadic C functions.
 */

#include <components/log.h>
#include <os/os.h>

void bk_zig_log(const char *tag, const char *msg) {
    BK_LOGI(tag, "%s\r\n", msg);
}

void bk_zig_log_int(const char *tag, const char *msg, int val) {
    BK_LOGI(tag, "%s%d\r\n", msg, val);
}

void bk_zig_delay_ms(unsigned int ms) {
    rtos_delay_milliseconds(ms);
}
