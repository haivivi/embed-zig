/**
 * bk_zig_helper.c — C bridge for Zig <-> Armino SDK interop.
 *
 * Armino uses variadic C macros (BK_LOGI, BK_LOGW, BK_LOGE) and
 * complex FreeRTOS wrappers that Zig's @cImport can't handle.
 * This file provides simple non-variadic C functions callable from Zig.
 */

#include <components/log.h>
#include <os/os.h>

/* ========================================================================
 * Logging
 * ======================================================================== */

void bk_zig_log(const char *tag, const char *msg) {
    BK_LOGI((char *)tag, "%s\r\n", (char *)msg);
}

void bk_zig_log_int(const char *tag, const char *msg, int val) {
    BK_LOGI((char *)tag, "%s%d\r\n", (char *)msg, val);
}

void bk_zig_log_warn(const char *tag, const char *msg) {
    BK_LOGW((char *)tag, "%s\r\n", (char *)msg);
}

void bk_zig_log_err(const char *tag, const char *msg) {
    BK_LOGE((char *)tag, "%s\r\n", (char *)msg);
}

/* ========================================================================
 * Time
 * ======================================================================== */

void bk_zig_delay_ms(unsigned int ms) {
    rtos_delay_milliseconds(ms);
}

extern uint64_t bk_aon_rtc_get_ms(void);

uint64_t bk_zig_get_time_ms(void) {
    return bk_aon_rtc_get_ms();
}

/* ========================================================================
 * RTOS / Thread
 * ======================================================================== */

typedef void (*bk_zig_thread_fn)(void *arg);

int bk_zig_create_thread(
    const char *name,
    bk_zig_thread_fn func,
    void *arg,
    unsigned int stack_size,
    unsigned int priority)
{
    beken_thread_t thread;
    int ret = rtos_create_thread(&thread,
                                 priority,
                                 name,
                                 (beken_thread_function_t)func,
                                 stack_size,
                                 arg);
    return ret;
}

/* ============================================================
 * ARM ABI helper functions required by Zig freestanding code.
 * GCC's libgcc provides these, but Zig's freestanding runtime
 * needs them explicitly when linked into an Armino project.
 * ============================================================ */

#include <string.h>

void __aeabi_memclr(void *dest, size_t n) {
    memset(dest, 0, n);
}

void __aeabi_memclr4(void *dest, size_t n) {
    memset(dest, 0, n);
}

void __aeabi_memclr8(void *dest, size_t n) {
    memset(dest, 0, n);
}
