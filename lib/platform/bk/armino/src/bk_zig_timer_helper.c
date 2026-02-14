/**
 * bk_zig_timer_helper.c — Hardware timer for Zig
 *
 * Uses BK7258 hardware timer (bk_timer_*), not RTOS software timer.
 * ISR-level precision, 6 channels total (timer2/3 system-reserved).
 *
 * Available: TIMER_ID0, TIMER_ID1, TIMER_ID4, TIMER_ID5 (4 channels)
 */

#include <driver/timer.h>
#include <components/log.h>

#define TAG "zig_timer"

/* Map user slot (0-3) to actual hardware timer ID, skipping reserved 2/3 */
static const int s_hw_timer_ids[4] = { 0, 1, 4, 5 }; /* TIMER_ID0,1,4,5 */
#define MAX_SLOTS 4

typedef void (*zig_timer_callback_t)(unsigned int slot);

static zig_timer_callback_t s_callbacks[MAX_SLOTS] = {0};
static int s_slot_used[MAX_SLOTS] = {0};

/* ISR trampoline — called in ISR context */
static void timer_isr_0(timer_id_t id) { (void)id; if (s_callbacks[0]) s_callbacks[0](0); }
static void timer_isr_1(timer_id_t id) { (void)id; if (s_callbacks[1]) s_callbacks[1](1); }
static void timer_isr_2(timer_id_t id) { (void)id; if (s_callbacks[2]) s_callbacks[2](2); }
static void timer_isr_3(timer_id_t id) { (void)id; if (s_callbacks[3]) s_callbacks[3](3); }

static timer_isr_t s_isr_table[MAX_SLOTS] = {
    timer_isr_0, timer_isr_1, timer_isr_2, timer_isr_3
};

/**
 * Start a periodic hardware timer.
 * @param period_ms  Period in milliseconds
 * @param callback   Zig callback (called in ISR context!)
 * @return slot (0-3), or -1 if no free slot
 */
int bk_zig_hw_timer_start(unsigned int period_ms, zig_timer_callback_t callback) {
    for (int i = 0; i < MAX_SLOTS; i++) {
        if (!s_slot_used[i]) {
            s_slot_used[i] = 1;
            s_callbacks[i] = callback;
            int ret = bk_timer_start(s_hw_timer_ids[i], period_ms, s_isr_table[i]);
            if (ret != 0) {
                BK_LOGE(TAG, "bk_timer_start(%d) failed: %d\r\n", s_hw_timer_ids[i], ret);
                s_slot_used[i] = 0;
                s_callbacks[i] = NULL;
                return -1;
            }
            return i;
        }
    }
    BK_LOGW(TAG, "no free hw timer slot\r\n");
    return -1;
}

/**
 * Start a one-shot hardware timer (microsecond precision).
 * @param delay_us   Delay in microseconds
 * @param callback   Zig callback (called in ISR context!)
 * @return slot (0-3), or -1 if no free slot
 */
int bk_zig_hw_timer_oneshot_us(unsigned long long delay_us, zig_timer_callback_t callback) {
    for (int i = 0; i < MAX_SLOTS; i++) {
        if (!s_slot_used[i]) {
            s_slot_used[i] = 1;
            s_callbacks[i] = callback;
            int ret = bk_timer_delay_with_callback(s_hw_timer_ids[i], delay_us, s_isr_table[i]);
            if (ret != 0) {
                BK_LOGE(TAG, "bk_timer_delay(%d) failed: %d\r\n", s_hw_timer_ids[i], ret);
                s_slot_used[i] = 0;
                s_callbacks[i] = NULL;
                return -1;
            }
            return i;
        }
    }
    return -1;
}

/**
 * Stop a hardware timer.
 * @param slot  Slot returned by start (0-3)
 */
void bk_zig_hw_timer_stop(int slot) {
    if (slot < 0 || slot >= MAX_SLOTS || !s_slot_used[slot]) return;
    bk_timer_stop(s_hw_timer_ids[slot]);
    s_callbacks[slot] = NULL;
    s_slot_used[slot] = 0;
}

/**
 * Get current counter value of a running timer.
 * @param slot  Slot (0-3)
 * @return counter value (counts down from period)
 */
unsigned int bk_zig_hw_timer_get_cnt(int slot) {
    if (slot < 0 || slot >= MAX_SLOTS) return 0;
    return bk_timer_get_cnt(s_hw_timer_ids[slot]);
}

/**
 * Get number of available (free) timer slots.
 */
int bk_zig_hw_timer_available(void) {
    int count = 0;
    for (int i = 0; i < MAX_SLOTS; i++) {
        if (!s_slot_used[i]) count++;
    }
    return count;
}
