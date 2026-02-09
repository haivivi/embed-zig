/**
 * @file bt_helper.h
 * @brief BLE Controller + VHCI transport helper for Zig integration
 *
 * This C helper wraps ESP-IDF Bluetooth controller and VHCI APIs because:
 * - BT_CONTROLLER_INIT_CONFIG_DEFAULT() is a complex macro with menuconfig deps
 * - esp_vhci_host_callback_t uses function pointers (opaque to Zig @cImport)
 * - VHCI uses async callbacks; we buffer into a ring buffer for poll-based read
 *
 * We expose simple byte-array interfaces that Zig can easily call.
 */

#ifndef BT_HELPER_H
#define BT_HELPER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize the BLE controller and enable VHCI transport
 *
 * Performs the full initialization sequence:
 * 1. Release classic BT memory (BLE-only mode)
 * 2. Initialize controller with default config
 * 3. Enable controller in BLE mode
 * 4. Register VHCI callbacks (internal ring buffer)
 *
 * @return 0 on success, negative error code on failure:
 *   -1: memory release failed
 *   -2: controller init failed
 *   -3: controller enable failed
 *   -4: VHCI callback registration failed
 */
int bt_helper_init(void);

/**
 * @brief Deinitialize the BLE controller
 *
 * Disables and deinitializes the controller, releases resources.
 */
void bt_helper_deinit(void);

/**
 * @brief Check if the controller is ready to accept a packet
 *
 * @return true if esp_vhci_host_send_packet() can be called
 */
bool bt_helper_can_send(void);

/**
 * @brief Send an HCI packet to the controller via VHCI
 *
 * The packet must include the HCI packet indicator byte:
 *   0x01 = Command, 0x02 = ACL Data, 0x03 = SCO Data
 *
 * @param data  Packet data (including indicator byte)
 * @param len   Packet length
 * @return 0 on success, -1 if not ready to send
 */
int bt_helper_send(const uint8_t *data, uint16_t len);

/**
 * @brief Read an HCI packet from the receive ring buffer
 *
 * Packets received from the controller via VHCI callback are stored
 * in an internal ring buffer. This function copies the next complete
 * packet (with indicator byte prepended) into the caller's buffer.
 *
 * @param buf      Output buffer
 * @param buf_len  Output buffer size
 * @return Number of bytes copied (>0), 0 if no packet available,
 *         -1 if buffer too small (packet is discarded)
 */
int bt_helper_recv(uint8_t *buf, uint16_t buf_len);

/**
 * @brief Check if there are packets available to read
 *
 * @return true if bt_helper_recv() would return data
 */
bool bt_helper_has_data(void);

/**
 * @brief Wait until data is available or timeout expires
 *
 * Blocks on an internal semaphore signaled by the VHCI RX callback.
 *
 * @param timeout_ms  Timeout in milliseconds (0 = non-blocking, portMAX_DELAY = forever)
 * @return true if data is available, false on timeout
 */
bool bt_helper_wait_for_data(uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* BT_HELPER_H */
