/**
 * bk_zig_ble_helper.c — BLE HCI transport for Zig (AP side, IPC to CP)
 *
 * BK7258 architecture: BLE controller runs on CP core.
 * AP accesses HCI through IPC (bt_ipc_hci_send_cmd / bt_ipc_register_hci_send_callback).
 *
 * Ring buffer + semaphore pattern for async receive from CP.
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

/* Ring buffer for HCI packets from CP controller */
#define HCI_BUF_SIZE 4096
static uint8_t s_ring_buf[HCI_BUF_SIZE];
static volatile uint32_t s_ring_head = 0;
static volatile uint32_t s_ring_tail = 0;
static beken_semaphore_t s_data_sem = NULL;
static int s_initialized = 0;

static uint32_t ring_used(void) {
    return (s_ring_head - s_ring_tail + HCI_BUF_SIZE) % HCI_BUF_SIZE;
}

static uint32_t ring_free(void) {
    return HCI_BUF_SIZE - 1 - ring_used();
}

static void ring_write(const uint8_t *data, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) {
        s_ring_buf[s_ring_head] = data[i];
        s_ring_head = (s_ring_head + 1) % HCI_BUF_SIZE;
    }
}

static uint32_t ring_read(uint8_t *data, uint32_t max_len) {
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
 * Format from IPC: [indicator_byte][hci_data...]
 * indicator: 0x04=event, 0x02=ACL data
 *
 * We store: [len_hi][len_lo][indicator][hci_data...]
 */
static void hci_from_controller_cb(uint8_t *buf, uint16_t len) {
    if (len == 0 || !s_initialized) return;

    uint32_t total = 2 + len; /* 2-byte length prefix + data */
    if (ring_free() < total) {
        BK_LOGW(TAG, "HCI ring full, dropping %d bytes\r\n", len);
        return;
    }

    uint8_t hdr[2] = { (uint8_t)(len >> 8), (uint8_t)(len & 0xFF) };
    ring_write(hdr, 2);
    ring_write(buf, len);

    if (s_data_sem) {
        rtos_set_semaphore(&s_data_sem);
    }
}

/**
 * Initialize BLE and register HCI callback on AP side.
 */
int bk_zig_ble_init(void) {
    if (s_initialized) return 0;

    int ret = rtos_init_semaphore(&s_data_sem, 128);
    if (ret != 0) {
        BK_LOGE(TAG, "sem init failed: %d\r\n", ret);
        return -1;
    }

    /* Initialize Bluetooth (enables IPC to CP) */
    ret = bk_bluetooth_init();
    if (ret != 0) {
        BK_LOGE(TAG, "bk_bluetooth_init failed: %d\r\n", ret);
        rtos_deinit_semaphore(&s_data_sem);
        return -2;
    }

    /* Register to receive HCI data from CP */
    bt_ipc_register_hci_send_callback(hci_from_controller_cb);

    s_initialized = 1;
    BK_LOGI(TAG, "BLE HCI initialized (AP→CP IPC)\r\n");
    return 0;
}

void bk_zig_ble_deinit(void) {
    if (!s_initialized) return;
    bt_ipc_register_hci_send_callback(NULL);
    s_initialized = 0;
    if (s_data_sem) {
        rtos_deinit_semaphore(&s_data_sem);
        s_data_sem = NULL;
    }
    s_ring_head = 0;
    s_ring_tail = 0;
}

/**
 * Send HCI command to CP controller.
 * buf format: [0x01][opcode_lo][opcode_hi][param_len][params...]
 */
int bk_zig_ble_send_cmd(const uint8_t *buf, unsigned int len) {
    if (len < 3) return -1; /* Need at least opcode + param_len */
    /* buf[0]=opcode_lo, buf[1]=opcode_hi, buf[2]=param_len, buf[3..]=params */
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
 * Receive an HCI packet from the ring buffer.
 * Returns: number of bytes read (including indicator byte), or 0 if empty.
 * Output format: [indicator][hci_payload...]
 */
unsigned int bk_zig_ble_recv(uint8_t *buf, unsigned int max_len) {
    if (ring_used() < 2) return 0;

    /* Peek length header */
    uint32_t saved_tail = s_ring_tail;
    uint8_t hdr[2];
    ring_read(hdr, 2);

    uint16_t pkt_len = ((uint16_t)hdr[0] << 8) | hdr[1];

    if (pkt_len > max_len) {
        s_ring_tail = saved_tail;
        return 0;
    }

    if (ring_used() < pkt_len) {
        s_ring_tail = saved_tail;
        return 0;
    }

    ring_read(buf, pkt_len);
    return pkt_len;
}

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

int bk_zig_ble_can_send(void) {
    return s_initialized ? 1 : 0;
}
