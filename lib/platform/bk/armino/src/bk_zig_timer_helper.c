/**
 * bk_zig_timer_helper.c — Software timer via RTOS timer
 *
 * Wraps FreeRTOS software timers for Zig.
 * Supports periodic and one-shot timers with callback.
 */

#include <os/os.h>
#include <components/log.h>

#define TAG "zig_timer"
#define MAX_TIMERS 8

typedef void (*zig_timer_callback_t)(unsigned int timer_id);

static beken_timer_t s_timers[MAX_TIMERS];
static beken2_timer_t s_oneshot_timers[MAX_TIMERS];
static int s_timer_used[MAX_TIMERS] = {0};
static int s_oneshot_used[MAX_TIMERS] = {0};
static zig_timer_callback_t s_callbacks[MAX_TIMERS] = {0};
static zig_timer_callback_t s_oneshot_callbacks[MAX_TIMERS] = {0};

/* Periodic timer callback trampoline */
static void timer_trampoline(void *arg) {
    unsigned int id = (unsigned int)(uintptr_t)arg;
    if (id < MAX_TIMERS && s_callbacks[id]) {
        s_callbacks[id](id);
    }
}

/* One-shot timer callback trampoline */
static void oneshot_trampoline(void *arg1, void *arg2) {
    (void)arg2;
    unsigned int id = (unsigned int)(uintptr_t)arg1;
    if (id < MAX_TIMERS && s_oneshot_callbacks[id]) {
        s_oneshot_callbacks[id](id);
    }
}

/**
 * Create and start a periodic timer.
 * @return timer handle (0..MAX_TIMERS-1), or -1 on error
 */
int bk_zig_timer_start_periodic(unsigned int period_ms, zig_timer_callback_t callback) {
    for (int i = 0; i < MAX_TIMERS; i++) {
        if (!s_timer_used[i]) {
            s_timer_used[i] = 1;
            s_callbacks[i] = callback;
            int ret = rtos_init_timer(&s_timers[i], period_ms,
                                       (timer_handler_t)timer_trampoline,
                                       (void *)(uintptr_t)i);
            if (ret != 0) {
                s_timer_used[i] = 0;
                return -1;
            }
            ret = rtos_start_timer(&s_timers[i]);
            if (ret != 0) {
                rtos_deinit_timer(&s_timers[i]);
                s_timer_used[i] = 0;
                return -1;
            }
            return i;
        }
    }
    return -1; /* No free slot */
}

/**
 * Create and start a one-shot timer.
 * @return timer handle (0..MAX_TIMERS-1), or -1 on error
 */
int bk_zig_timer_start_oneshot(unsigned int delay_ms, zig_timer_callback_t callback) {
    for (int i = 0; i < MAX_TIMERS; i++) {
        if (!s_oneshot_used[i]) {
            s_oneshot_used[i] = 1;
            s_oneshot_callbacks[i] = callback;
            int ret = rtos_init_oneshot_timer(&s_oneshot_timers[i], delay_ms,
                                               (timer_2handler_t)oneshot_trampoline,
                                               (void *)(uintptr_t)i,
                                               NULL);
            if (ret != 0) {
                s_oneshot_used[i] = 0;
                return -1;
            }
            ret = rtos_start_oneshot_timer(&s_oneshot_timers[i]);
            if (ret != 0) {
                rtos_deinit_oneshot_timer(&s_oneshot_timers[i]);
                s_oneshot_used[i] = 0;
                return -1;
            }
            return i;
        }
    }
    return -1;
}

/**
 * Stop and free a periodic timer.
 */
void bk_zig_timer_stop_periodic(int handle) {
    if (handle < 0 || handle >= MAX_TIMERS || !s_timer_used[handle]) return;
    rtos_stop_timer(&s_timers[handle]);
    rtos_deinit_timer(&s_timers[handle]);
    s_callbacks[handle] = NULL;
    s_timer_used[handle] = 0;
}

/**
 * Stop and free a one-shot timer.
 */
void bk_zig_timer_stop_oneshot(int handle) {
    if (handle < 0 || handle >= MAX_TIMERS || !s_oneshot_used[handle]) return;
    rtos_stop_oneshot_timer(&s_oneshot_timers[handle]);
    rtos_deinit_oneshot_timer(&s_oneshot_timers[handle]);
    s_oneshot_callbacks[handle] = NULL;
    s_oneshot_used[handle] = 0;
}
