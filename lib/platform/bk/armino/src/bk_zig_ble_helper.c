/**
 * bk_zig_ble_helper.c — BLE HCI transport for Zig (AP side, IPC to CP)
 *
 * BK7258 architecture: BLE controller runs on CP core.
 * AP accesses HCI through IPC (bt_ipc_hci_send_cmd / bt_ipc_register_hci_send_callback).
 *
 * Ring buffer (32KB) + semaphore + mutex for thread-safe async receive.
 */

#include <string.h>
#include <os/os.h>
#include <components/log.h>
#include <components/bluetooth/bk_dm_bluetooth.h>

/* AP-side IPC interface to CP BLE controller */
extern void bt_ipc_init(void);
extern void bt_ipc_hci_send_cmd(uint16_t opcode, uint8_t *data, uint16_t len);
extern void bt_ipc_hci_send_acl_data(uint16_t hdl_flags, uint8_t *data, uint16_t len);
typedef void (*bt_hci_send_cb_t)(uint8_t *buf, uint16_t len);
extern void bt_ipc_register_hci_send_callback(bt_hci_send_cb_t cb);

#define TAG "zig_ble"

/* Ring buffer for HCI packets from CP controller — 32KB for sustained ACL */
#define HCI_BUF_SIZE (32 * 1024)
static uint8_t s_ring_buf[HCI_BUF_SIZE];
static volatile uint32_t s_ring_head = 0;
static volatile uint32_t s_ring_tail = 0;
static beken_semaphore_t s_data_sem = NULL;
static beken_mutex_t s_ring_mutex = NULL;
static int s_initialized = 0;
static uint32_t s_drop_count = 0;

static uint32_t ring_used(void) {
    return (s_ring_head - s_ring_tail + HCI_BUF_SIZE) % HCI_BUF_SIZE;
}

static uint32_t ring_free(void) {
    return HCI_BUF_SIZE - 1 - ring_used();
}

static void ring_write_unlocked(const uint8_t *data, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) {
        s_ring_buf[s_ring_head] = data[i];
        s_ring_head = (s_ring_head + 1) % HCI_BUF_SIZE;
    }
}

static uint32_t ring_read_unlocked(uint8_t *data, uint32_t max_len) {
    uint32_t avail = ring_used();
    uint32_t to_read = (avail < max_len) ? avail : max_len;
    for (uint32_t i = 0; i < to_read; i++) {
        data[i] = s_ring_buf[s_ring_tail];
        s_ring_tail = (s_ring_tail + 1) % HCI_BUF_SIZE;
    }
    return to_read;
}

/**
 * IPC callback: CP sends HCI data to AP.
 * Format: [indicator_byte][hci_data...]
 * We store: [len_hi][len_lo][indicator][hci_data...]
 *
 * NOTE: This may be called from IPC interrupt context on BK7258.
 */
static void hci_from_controller_cb(uint8_t *buf, uint16_t len) {
    if (len == 0 || !s_initialized) return;

    /* Lock mutex (safe from task context; if ISR, use critical section) */
    if (s_ring_mutex) rtos_lock_mutex(&s_ring_mutex);

    uint32_t total = 2 + len;
    if (ring_free() < total) {
        s_drop_count++;
        if ((s_drop_count % 100) == 1) {
            BK_LOGW(TAG, "HCI ring full! dropped=%d, used=%d/%d\r\n",
                     s_drop_count, ring_used(), HCI_BUF_SIZE);
        }
        if (s_ring_mutex) rtos_unlock_mutex(&s_ring_mutex);
        return;
    }

    uint8_t hdr[2] = { (uint8_t)(len >> 8), (uint8_t)(len & 0xFF) };
    ring_write_unlocked(hdr, 2);
    ring_write_unlocked(buf, len);

    if (s_ring_mutex) rtos_unlock_mutex(&s_ring_mutex);

    if (s_data_sem) {
        rtos_set_semaphore(&s_data_sem);
    }
}

/**
 * Initialize BLE and register HCI callback.
 */
int bk_zig_ble_init(void) {
    if (s_initialized) return 0;

    int ret = rtos_init_semaphore(&s_data_sem, 256);
    if (ret != 0) {
        BK_LOGE(TAG, "sem init failed: %d\r\n", ret);
        return -1;
    }

    ret = rtos_init_mutex(&s_ring_mutex);
    if (ret != 0) {
        BK_LOGE(TAG, "mutex init failed: %d\r\n", ret);
        rtos_deinit_semaphore(&s_data_sem);
        return -1;
    }

    ret = bk_bluetooth_init();
    if (ret != 0) {
        BK_LOGE(TAG, "bk_bluetooth_init failed: %d\r\n", ret);
        rtos_deinit_semaphore(&s_data_sem);
        rtos_deinit_mutex(&s_ring_mutex);
        return -2;
    }

    bt_ipc_register_hci_send_callback(hci_from_controller_cb);

    s_initialized = 1;
    s_drop_count = 0;
    BK_LOGI(TAG, "BLE HCI initialized (AP->CP IPC, ring=%dKB)\r\n", HCI_BUF_SIZE / 1024);
    return 0;
}

void bk_zig_ble_deinit(void) {
    if (!s_initialized) return;
    bt_ipc_register_hci_send_callback(NULL);
    s_initialized = 0;
    if (s_data_sem) { rtos_deinit_semaphore(&s_data_sem); s_data_sem = NULL; }
    if (s_ring_mutex) { rtos_deinit_mutex(&s_ring_mutex); s_ring_mutex = NULL; }
    s_ring_head = 0;
    s_ring_tail = 0;
    if (s_drop_count > 0) {
        BK_LOGW(TAG, "Total HCI drops: %d\r\n", s_drop_count);
    }
}

/**
 * Send HCI command to CP controller.
 * buf format: [opcode_lo][opcode_hi][param_len][params...]
 */
int bk_zig_ble_send_cmd(const uint8_t *buf, unsigned int len) {
    if (len < 3) return -1;
    uint16_t opcode = ((uint16_t)buf[1] << 8) | buf[0];
    uint8_t param_len = buf[2];
    bt_ipc_hci_send_cmd(opcode, (uint8_t *)(buf + 3), param_len);
    return 0;
}

/**
 * Send HCI ACL data to CP controller.
 * buf format: [handle_lo][handle_hi][len_lo][len_hi][data...]
 */
int bk_zig_ble_send_acl(const uint8_t *buf, unsigned int len) {
    if (len < 4) return -1;
    uint16_t hdl_flags = ((uint16_t)buf[1] << 8) | buf[0];
    uint16_t data_len = ((uint16_t)buf[3] << 8) | buf[2];
    bt_ipc_hci_send_acl_data(hdl_flags, (uint8_t *)(buf + 4), data_len);
    return 0;
}

/**
 * Receive an HCI packet from the ring buffer (thread-safe).
 * Returns: bytes read (indicator + payload), or 0 if empty.
 */
unsigned int bk_zig_ble_recv(uint8_t *buf, unsigned int max_len) {
    if (s_ring_mutex) rtos_lock_mutex(&s_ring_mutex);

    if (ring_used() < 2) {
        if (s_ring_mutex) rtos_unlock_mutex(&s_ring_mutex);
        return 0;
    }

    /* Peek length header */
    uint32_t saved_tail = s_ring_tail;
    uint8_t hdr[2];
    ring_read_unlocked(hdr, 2);

    uint16_t pkt_len = ((uint16_t)hdr[0] << 8) | hdr[1];

    if (pkt_len > max_len || ring_used() < pkt_len) {
        /* Can't read — restore tail */
        s_ring_tail = saved_tail;
        if (s_ring_mutex) rtos_unlock_mutex(&s_ring_mutex);
        return 0;
    }

    ring_read_unlocked(buf, pkt_len);
    if (s_ring_mutex) rtos_unlock_mutex(&s_ring_mutex);
    return pkt_len;
}

/**
 * Wait for data with timeout.
 */
int bk_zig_ble_wait_for_data(int timeout_ms) {
    /* Fast path: data already available */
    if (ring_used() > 0) return 1;
    if (!s_data_sem) return 0;

    uint32_t ticks;
    if (timeout_ms < 0) ticks = BEKEN_WAIT_FOREVER;
    else if (timeout_ms == 0) ticks = 0;
    else ticks = timeout_ms;

    int ret = rtos_get_semaphore(&s_data_sem, ticks);
    /* After semaphore, check ring again (could be spurious wakeup) */
    return (ret == 0 && ring_used() > 0) ? 1 : 0;
}

int bk_zig_ble_can_send(void) {
    return s_initialized ? 1 : 0;
}
