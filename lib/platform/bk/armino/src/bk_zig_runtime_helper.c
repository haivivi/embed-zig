/**
 * bk_zig_runtime_helper.c — FreeRTOS sync primitives for Zig Runtime.
 *
 * Provides Mutex, Condition (counting semaphore), and spawn for
 * cross-platform async packages (Channel, WaitGroup, TLS, etc).
 */

#include <os/os.h>
#include <os/mem.h>
#include <components/log.h>

#define TAG "zig_rt"

/* ============================================================
 * Mutex — Armino rtos_*_mutex wrappers
 * ============================================================ */

void *bk_zig_mutex_create(void)
{
    beken_mutex_t mutex = NULL;
    if (rtos_init_mutex(&mutex) != kNoErr) return NULL;
    return (void *)mutex;
}

void bk_zig_mutex_destroy(void *handle)
{
    if (handle) {
        beken_mutex_t m = (beken_mutex_t)handle;
        rtos_deinit_mutex(&m);
    }
}

void bk_zig_mutex_lock(void *handle)
{
    if (handle) {
        beken_mutex_t m = (beken_mutex_t)handle;
        rtos_lock_mutex(&m);
    }
}

void bk_zig_mutex_unlock(void *handle)
{
    if (handle) {
        beken_mutex_t m = (beken_mutex_t)handle;
        rtos_unlock_mutex(&m);
    }
}

/* ============================================================
 * Condition — counting semaphore (max=64, init=0)
 * ============================================================ */

void *bk_zig_cond_create(void)
{
    beken_semaphore_t sem = NULL;
    if (rtos_init_semaphore_ex(&sem, 64, 0) != kNoErr) return NULL;
    return (void *)sem;
}

void bk_zig_cond_destroy(void *handle)
{
    if (handle) {
        beken_semaphore_t s = (beken_semaphore_t)handle;
        rtos_deinit_semaphore(&s);
    }
}

void bk_zig_cond_signal(void *handle)
{
    if (handle) {
        beken_semaphore_t s = (beken_semaphore_t)handle;
        rtos_set_semaphore(&s);
    }
}

/* Wait with timeout (ms). Returns 0=signaled, 1=timeout */
int bk_zig_cond_wait(void *handle, unsigned int timeout_ms)
{
    if (!handle) return 1;
    beken_semaphore_t s = (beken_semaphore_t)handle;
    return (rtos_get_semaphore(&s, timeout_ms) == kNoErr) ? 0 : 1;
}

/* ============================================================
 * Spawn — FreeRTOS task creation
 * ============================================================ */

int bk_zig_spawn(const char *name,
                 void (*func)(void *arg),
                 void *arg,
                 unsigned int stack_size,
                 unsigned int priority)
{
    beken_thread_t handle = NULL;
    int ret = rtos_create_thread(&handle, priority, name,
                                 (beken_thread_function_t)func,
                                 stack_size, arg);
    return (ret == kNoErr) ? 0 : -1;
}

/* ============================================================
 * Time
 * ============================================================ */

unsigned long long bk_zig_now_ms(void)
{
    return (unsigned long long)rtos_get_time();
}

void bk_zig_sleep_ms(unsigned int ms)
{
    rtos_delay_milliseconds(ms);
}

/* ============================================================
 * CPU count
 * ============================================================ */

int bk_zig_get_cpu_count(void)
{
    return 2;  /* BK7258 = dual core AP + CP */
}
