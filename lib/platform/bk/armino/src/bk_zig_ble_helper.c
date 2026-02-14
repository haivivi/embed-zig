/**
 * bk_zig_ble_helper.c — BLE HCI transport for Zig
 *
 * Ring buffer + semaphore pattern (same as ESP bt_helper.c).
 * Receives HCI events/ACL from BLE controller via callbacks,
 * buffers them in a ring buffer for Zig to read via poll/recv.
 *
 * BK7258 BLE runs on CP core, HCI goes through IPC.
 */

#include <string.h>
#include <os/os.h>
#include <components/log.h>
#include <components/bluetooth/bk_ble.h>
#include <components/bluetooth/bk_ble_types.h>
#include <components/bluetooth/bk_dm_bluetooth.h>

#define TAG "zig_ble"

/* Ring buffer for HCI packets from controller */
#define HCI_BUF_SIZE 4096
static uint8_t s_ring_buf[HCI_BUF_SIZE];
static volatile uint32_t s_ring_head = 0;
static volatile uint32_t s_ring_tail = 0;
static beken_semaphore_t s_data_sem = NULL;
static int s_initialized = 0;

static uint32_t ring_used(void) {
    return (s_ring_head - s_ring_tail) % HCI_BUF_SIZE;
}

static uint32_t ring_free(void) {
    return HCI_BUF_SIZE - 1 - ring_used();
}

static void ring_write(const uint8_t *data, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) {
        s_ring_buf[s_ring_head % HCI_BUF_SIZE] = data[i];
        s_ring_head = (s_ring_head + 1) % HCI_BUF_SIZE;
    }
}

static uint32_t ring_read(uint8_t *data, uint32_t max_len) {
    uint32_t avail = ring_used();
    uint32_t to_read = (avail < max_len) ? avail : max_len;
    for (uint32_t i = 0; i < to_read; i++) {
        data[i] = s_ring_buf[s_ring_tail % HCI_BUF_SIZE];
        s_ring_tail = (s_ring_tail + 1) % HCI_BUF_SIZE;
    }
    return to_read;
}

/* Store a packet with: [indicator][len_hi][len_lo][payload...] */
static void store_packet(uint8_t indicator, const uint8_t *buf, uint16_t len) {
    uint32_t total = 3 + len; /* indicator + 2-byte len + payload */
    if (ring_free() < total) {
        BK_LOGW(TAG, "HCI ring full, dropping %d bytes\r\n", len);
        return;
    }
    uint8_t hdr[3] = { indicator, (uint8_t)(len >> 8), (uint8_t)(len & 0xFF) };
    ring_write(hdr, 3);
    ring_write(buf, len);

    if (s_data_sem) {
        rtos_set_semaphore(&s_data_sem);
    }
}

/* HCI Event callback from controller */
static ble_err_t hci_evt_callback(uint8_t *buf, uint16_t len) {
    store_packet(0x04, buf, len); /* 0x04 = HCI Event */
    return 0;
}

/* HCI ACL Data callback from controller */
static ble_err_t hci_acl_callback(uint8_t *buf, uint16_t len) {
    store_packet(0x02, buf, len); /* 0x02 = HCI ACL Data */
    return 0;
}

/**
 * Initialize BLE controller and register HCI callbacks.
 * @return 0 on success
 */
int bk_zig_ble_init(void) {
    if (s_initialized) return 0;

    int ret = rtos_init_semaphore(&s_data_sem, 128);
    if (ret != 0) {
        BK_LOGE(TAG, "sem init failed: %d\r\n", ret);
        return -1;
    }

    /* Initialize Bluetooth stack */
    ret = bk_bluetooth_init();
    if (ret != 0) {
        BK_LOGE(TAG, "bk_bluetooth_init failed: %d\r\n", ret);
        rtos_deinit_semaphore(&s_data_sem);
        return -2;
    }

    /* Register HCI receive callbacks */
    ret = bk_ble_reg_hci_recv_callback(hci_evt_callback, hci_acl_callback);
    if (ret != 0) {
        BK_LOGE(TAG, "reg_hci_recv_callback failed: %d\r\n", ret);
        return -3;
    }

    s_initialized = 1;
    BK_LOGI(TAG, "BLE HCI initialized\r\n");
    return 0;
}

/**
 * Deinitialize BLE.
 */
void bk_zig_ble_deinit(void) {
    if (!s_initialized) return;
    /* Note: Armino may not support full BLE deinit.
     * Clear our state only. */
    s_initialized = 0;
    if (s_data_sem) {
        rtos_deinit_semaphore(&s_data_sem);
        s_data_sem = NULL;
    }
    s_ring_head = 0;
    s_ring_tail = 0;
}

/**
 * Send HCI command to controller.
 * @param buf HCI command payload (without indicator byte)
 * @param len Length
 * @return 0 on success
 */
int bk_zig_ble_send_cmd(const uint8_t *buf, unsigned int len) {
    return bk_ble_hci_cmd_to_controller((uint8_t *)buf, len);
}

/**
 * Send HCI ACL data to controller.
 * @param buf ACL data payload (without indicator byte)
 * @param len Length
 * @return 0 on success
 */
int bk_zig_ble_send_acl(const uint8_t *buf, unsigned int len) {
    return bk_ble_hci_acl_to_controller((uint8_t *)buf, len);
}

/**
 * Receive an HCI packet from the ring buffer.
 * Returns: number of bytes read (including indicator), or 0 if empty.
 * Format: [indicator][payload...]
 */
unsigned int bk_zig_ble_recv(uint8_t *buf, unsigned int max_len) {
    if (ring_used() < 3) return 0; /* Need at least header */

    /* Peek at the header */
    uint8_t hdr[3];
    uint32_t saved_tail = s_ring_tail;
    ring_read(hdr, 3);

    uint16_t payload_len = ((uint16_t)hdr[1] << 8) | hdr[2];
    uint32_t total = 1 + payload_len; /* indicator + payload */

    if (total > max_len) {
        /* Not enough space — restore tail and return 0 */
        s_ring_tail = saved_tail;
        return 0;
    }

    if (ring_used() < payload_len) {
        /* Incomplete packet (shouldn't happen) — restore */
        s_ring_tail = saved_tail;
        return 0;
    }

    buf[0] = hdr[0]; /* indicator */
    ring_read(buf + 1, payload_len);
    return total;
}

/**
 * Wait for data to be available.
 * @param timeout_ms -1=forever, 0=poll, >0=wait ms
 * @return 1 if data available, 0 if timeout
 */
int bk_zig_ble_wait_for_data(int timeout_ms) {
    if (ring_used() > 0) return 1;
    if (!s_data_sem) return 0;

    uint32_t ticks;
    if (timeout_ms < 0) ticks = BEKEN_WAIT_FOREVER;
    else if (timeout_ms == 0) ticks = 0;
    else ticks = timeout_ms;

    int ret = rtos_get_semaphore(&s_data_sem, ticks);
    return (ret == 0) ? 1 : 0;
}

/**
 * Check if send is possible (always true for BK — IPC handles flow control).
 */
int bk_zig_ble_can_send(void) {
    return s_initialized ? 1 : 0;
}
