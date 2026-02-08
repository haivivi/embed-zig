/**
 * @file bt_helper.c
 * @brief BLE Controller + VHCI transport helper implementation
 *
 * Uses a simple packet ring buffer to bridge the async VHCI callback
 * to a synchronous poll/read model that Zig can use.
 *
 * Ring buffer stores complete HCI packets with a 2-byte length prefix:
 *   [len_lo][len_hi][indicator][hci_payload...]
 *
 * The indicator byte (0x04 for events, 0x02 for ACL) is prepended by
 * the notify_host_recv callback since the controller doesn't include it.
 *
 * Thread safety:
 * - notify_host_recv is called from the BT controller task
 * - bt_helper_recv is called from the Zig host task
 * - We use a FreeRTOS critical section (spinlock) to protect the ring buffer
 */

#include "bt_helper.h"

#include <string.h>
#include "esp_bt.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

static const char *TAG = "bt_helper";

/* ========================================================================== */
/* Ring Buffer for RX packets                                                 */
/* ========================================================================== */

/**
 * Ring buffer size: 4KB should handle ~10-20 typical HCI events/ACL packets.
 * Each packet is stored as: [len_lo][len_hi][data...]
 * Max single HCI packet: 255 (event) or 27+4 (LE ACL) typically.
 */
#define RX_RING_SIZE 4096

static uint8_t rx_ring[RX_RING_SIZE];
static volatile uint16_t rx_head = 0;  /* write position */
static volatile uint16_t rx_tail = 0;  /* read position */
static portMUX_TYPE rx_lock = portMUX_INITIALIZER_UNLOCKED;

/**
 * Available bytes in ring buffer (must be called with lock held)
 */
static inline uint16_t ring_used(void) {
    return (uint16_t)((rx_head - rx_tail) % RX_RING_SIZE);
}

/**
 * Free bytes in ring buffer (must be called with lock held)
 */
static inline uint16_t ring_free(void) {
    return (uint16_t)(RX_RING_SIZE - 1 - ring_used());
}

/**
 * Write bytes to ring buffer (must be called with lock held)
 * Returns false if not enough space.
 */
static bool ring_write(const uint8_t *data, uint16_t len) {
    if (ring_free() < len) {
        return false;
    }
    for (uint16_t i = 0; i < len; i++) {
        rx_ring[rx_head] = data[i];
        rx_head = (rx_head + 1) % RX_RING_SIZE;
    }
    return true;
}

/**
 * Read bytes from ring buffer (must be called with lock held)
 */
static void ring_read(uint8_t *buf, uint16_t len) {
    for (uint16_t i = 0; i < len; i++) {
        buf[i] = rx_ring[rx_tail];
        rx_tail = (rx_tail + 1) % RX_RING_SIZE;
    }
}

/**
 * Peek bytes from ring buffer without consuming (must be called with lock held)
 */
static void ring_peek(uint8_t *buf, uint16_t len) {
    uint16_t pos = rx_tail;
    for (uint16_t i = 0; i < len; i++) {
        buf[i] = rx_ring[pos];
        pos = (pos + 1) % RX_RING_SIZE;
    }
}

/**
 * Skip bytes in ring buffer (must be called with lock held)
 */
static void ring_skip(uint16_t len) {
    rx_tail = (rx_tail + len) % RX_RING_SIZE;
}

/* ========================================================================== */
/* Semaphore for blocking poll                                                */
/* ========================================================================== */

static SemaphoreHandle_t rx_sem = NULL;

/* ========================================================================== */
/* VHCI Callbacks                                                             */
/* ========================================================================== */

/**
 * Called by controller when it's ready to accept a new packet from host.
 * We don't need to track this — Zig calls bt_helper_can_send() before sending.
 */
static void on_host_send_available(void) {
    /* Nothing to do — Zig polls bt_helper_can_send() */
}

/**
 * Called by controller when it has a packet for the host.
 * The data includes the HCI indicator byte (0x02=ACL, 0x04=Event).
 *
 * We store the complete packet in the ring buffer with a 2-byte length prefix.
 * Format: [len_lo][len_hi][indicator][payload...]
 */
static int on_host_recv(uint8_t *data, uint16_t len) {
    if (len == 0) {
        return 0;
    }

    uint16_t total = 2 + len;  /* 2-byte length prefix + packet data */

    portENTER_CRITICAL(&rx_lock);

    if (ring_free() < total) {
        portEXIT_CRITICAL(&rx_lock);
        ESP_LOGW(TAG, "RX ring full, dropping %u byte packet", len);
        return 0;
    }

    /* Write length prefix (little-endian) */
    uint8_t hdr[2] = { (uint8_t)(len & 0xFF), (uint8_t)(len >> 8) };
    ring_write(hdr, 2);

    /* Write packet data (indicator + payload) */
    ring_write(data, len);

    portEXIT_CRITICAL(&rx_lock);

    /* Wake up any thread blocked in poll */
    if (rx_sem != NULL) {
        xSemaphoreGive(rx_sem);
    }

    return 0;
}

static const esp_vhci_host_callback_t vhci_callbacks = {
    .notify_host_send_available = on_host_send_available,
    .notify_host_recv = on_host_recv,
};

/* ========================================================================== */
/* Public API                                                                 */
/* ========================================================================== */

int bt_helper_init(void) {
    esp_err_t ret;

    /* Create RX semaphore for blocking poll */
    if (rx_sem == NULL) {
        rx_sem = xSemaphoreCreateBinary();
        if (rx_sem == NULL) {
            ESP_LOGE(TAG, "Failed to create RX semaphore");
            return -5;
        }
    }

    /* Reset ring buffer */
    portENTER_CRITICAL(&rx_lock);
    rx_head = 0;
    rx_tail = 0;
    portEXIT_CRITICAL(&rx_lock);

    /* 1. Release classic BT memory (we only use BLE) */
    ret = esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "BT mem release failed: %s", esp_err_to_name(ret));
        return -1;
    }

    /* 2. Initialize controller with default config */
    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ret = esp_bt_controller_init(&bt_cfg);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "BT controller init failed: %s", esp_err_to_name(ret));
        return -2;
    }

    /* 3. Enable controller in BLE mode */
    ret = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "BT controller enable failed: %s", esp_err_to_name(ret));
        esp_bt_controller_deinit();
        return -3;
    }

    /* 4. Register VHCI callbacks */
    ret = esp_vhci_host_register_callback(&vhci_callbacks);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "VHCI callback register failed: %s", esp_err_to_name(ret));
        esp_bt_controller_disable();
        esp_bt_controller_deinit();
        return -4;
    }

    ESP_LOGI(TAG, "BLE controller initialized (VHCI mode)");
    return 0;
}

void bt_helper_deinit(void) {
    esp_bt_controller_disable();
    esp_bt_controller_deinit();

    if (rx_sem != NULL) {
        vSemaphoreDelete(rx_sem);
        rx_sem = NULL;
    }

    ESP_LOGI(TAG, "BLE controller deinitialized");
}

bool bt_helper_can_send(void) {
    return esp_vhci_host_check_send_available();
}

int bt_helper_send(const uint8_t *data, uint16_t len) {
    if (!esp_vhci_host_check_send_available()) {
        return -1;
    }
    esp_vhci_host_send_packet((uint8_t *)data, len);
    return 0;
}

int bt_helper_recv(uint8_t *buf, uint16_t buf_len) {
    portENTER_CRITICAL(&rx_lock);

    uint16_t used = ring_used();
    if (used < 2) {
        portEXIT_CRITICAL(&rx_lock);
        return 0;  /* No packet available */
    }

    /* Peek at the length prefix */
    uint8_t hdr[2];
    ring_peek(hdr, 2);
    uint16_t pkt_len = (uint16_t)(hdr[0] | (hdr[1] << 8));

    if (used < (uint16_t)(2 + pkt_len)) {
        /* Incomplete packet — shouldn't happen since we write atomically */
        portEXIT_CRITICAL(&rx_lock);
        ESP_LOGW(TAG, "Incomplete packet in ring (need %u, have %u)", 2 + pkt_len, used);
        return 0;
    }

    if (pkt_len > buf_len) {
        /* Buffer too small — discard packet */
        ring_skip(2 + pkt_len);
        portEXIT_CRITICAL(&rx_lock);
        ESP_LOGW(TAG, "RX buffer too small (%u < %u), discarding", buf_len, pkt_len);
        return -1;
    }

    /* Skip length prefix */
    ring_skip(2);

    /* Read packet data */
    ring_read(buf, pkt_len);

    portEXIT_CRITICAL(&rx_lock);

    return (int)pkt_len;
}

bool bt_helper_has_data(void) {
    portENTER_CRITICAL(&rx_lock);
    bool has = (ring_used() >= 2);
    portEXIT_CRITICAL(&rx_lock);
    return has;
}
