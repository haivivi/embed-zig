/**
 * @file cb_helper.h
 * @brief CoreBluetooth C wrapper for Zig integration
 *
 * Wraps Apple's CoreBluetooth Objective-C API into a C-callable interface.
 * Provides both Peripheral (GATT Server) and Central (GATT Client) roles.
 *
 * CoreBluetooth replaces our entire HCI→L2CAP→ATT→GAP stack — Apple handles
 * all the low-level BLE protocol internally.
 */

#ifndef CB_HELPER_H
#define CB_HELPER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Characteristic Properties (mirror BLE spec)
// ============================================================================

enum {
    CB_PROP_READ              = 0x02,
    CB_PROP_WRITE_NO_RSP      = 0x04,
    CB_PROP_WRITE             = 0x08,
    CB_PROP_NOTIFY            = 0x10,
    CB_PROP_INDICATE          = 0x20,
};

// ============================================================================
// Callbacks (set by Zig before starting)
// ============================================================================

/**
 * Called when a central device reads a characteristic.
 * Implementation should fill `out` with data and set `out_len`.
 */
typedef void (*cb_read_callback_t)(
    const char *svc_uuid, const char *chr_uuid,
    uint8_t *out, uint16_t *out_len, uint16_t max_len
);

/**
 * Called when a central device writes to a characteristic.
 */
typedef void (*cb_write_callback_t)(
    const char *svc_uuid, const char *chr_uuid,
    const uint8_t *data, uint16_t len
);

/**
 * Called when a central subscribes/unsubscribes to notifications.
 */
typedef void (*cb_subscribe_callback_t)(
    const char *svc_uuid, const char *chr_uuid, bool subscribed
);

/**
 * Called when connection state changes.
 */
typedef void (*cb_connection_callback_t)(bool connected);

/**
 * Called when a device is discovered during scanning (Central role).
 */
typedef void (*cb_device_found_callback_t)(
    const char *name, const char *uuid, int rssi
);

/**
 * Called when a notification is received from server (Central role).
 */
typedef void (*cb_notification_callback_t)(
    const char *svc_uuid, const char *chr_uuid,
    const uint8_t *data, uint16_t len
);

// ============================================================================
// Peripheral (GATT Server) API
// ============================================================================

/** Set callbacks before calling init. */
void cb_peripheral_set_read_callback(cb_read_callback_t cb);
void cb_peripheral_set_write_callback(cb_write_callback_t cb);
void cb_peripheral_set_subscribe_callback(cb_subscribe_callback_t cb);
void cb_peripheral_set_connection_callback(cb_connection_callback_t cb);

/** Initialize the peripheral manager. Call once at startup. */
int cb_peripheral_init(void);

/**
 * Add a service with characteristics.
 *
 * @param svc_uuid  Service UUID string (e.g., "AA00" or full 128-bit)
 * @param chr_uuids Array of characteristic UUID strings
 * @param chr_props Array of property bitmasks (CB_PROP_*)
 * @param chr_count Number of characteristics
 * @return 0 on success
 */
int cb_peripheral_add_service(
    const char *svc_uuid,
    const char **chr_uuids,
    const uint8_t *chr_props,
    uint16_t chr_count
);

/** Start advertising with the given local name. */
int cb_peripheral_start_advertising(const char *name);

/** Stop advertising. */
void cb_peripheral_stop_advertising(void);

/**
 * Send a notification/indication to subscribed centrals (non-blocking).
 *
 * @param svc_uuid  Service UUID
 * @param chr_uuid  Characteristic UUID
 * @param data      Data to send
 * @param len       Data length
 * @return 0 on success, -2 char not found, -3 queue full
 */
int cb_peripheral_notify(
    const char *svc_uuid, const char *chr_uuid,
    const uint8_t *data, uint16_t len
);

/**
 * Send a notification with flow control (blocking).
 *
 * If the CoreBluetooth transmit queue is full, waits for the
 * peripheralManagerIsReadyToUpdateSubscribers delegate callback
 * before retrying. This is the correct way to handle high-throughput
 * notification sending per Apple's documentation.
 *
 * @param svc_uuid    Service UUID
 * @param chr_uuid    Characteristic UUID
 * @param data        Data to send
 * @param len         Data length
 * @param timeout_ms  Maximum wait time for queue space (ms)
 * @return 0 on success, -2 char not found, -3 still full after retry, -4 timeout
 */
int cb_peripheral_notify_blocking(
    const char *svc_uuid, const char *chr_uuid,
    const uint8_t *data, uint16_t len,
    uint32_t timeout_ms
);

/** Deinitialize and clean up. */
void cb_peripheral_deinit(void);

// ============================================================================
// Central (GATT Client) API
// ============================================================================

/** Set callbacks for central role. */
void cb_central_set_device_found_callback(cb_device_found_callback_t cb);
void cb_central_set_notification_callback(cb_notification_callback_t cb);
void cb_central_set_connection_callback(cb_connection_callback_t cb);

/** Initialize the central manager. */
int cb_central_init(void);

/** Start scanning for peripherals. */
int cb_central_scan_start(const char *service_uuid_filter);

/** Stop scanning. */
void cb_central_scan_stop(void);

/**
 * Connect to a discovered peripheral by UUID.
 *
 * @param peripheral_uuid  UUID string from device_found callback
 * @return 0 on success (connection initiated, wait for callback)
 */
int cb_central_connect(const char *peripheral_uuid);

/** Disconnect from the connected peripheral. */
void cb_central_disconnect(void);

/**
 * Force re-discovery of GATT services.
 *
 * Disconnects and reconnects to clear CoreBluetooth's GATT cache.
 * Use when discovered UUIDs don't match expected values (stale cache).
 *
 * @return 0 on success
 */
int cb_central_rediscover(void);

/**
 * Read a characteristic value (blocking).
 *
 * @param svc_uuid  Service UUID
 * @param chr_uuid  Characteristic UUID
 * @param out       Output buffer
 * @param out_len   Output: actual data length
 * @param max_len   Maximum buffer size
 * @return 0 on success
 */
int cb_central_read(
    const char *svc_uuid, const char *chr_uuid,
    uint8_t *out, uint16_t *out_len, uint16_t max_len
);

/**
 * Write a characteristic value (blocking, with response).
 */
int cb_central_write(
    const char *svc_uuid, const char *chr_uuid,
    const uint8_t *data, uint16_t len
);

/**
 * Write without response.
 */
int cb_central_write_no_response(
    const char *svc_uuid, const char *chr_uuid,
    const uint8_t *data, uint16_t len
);

/**
 * Subscribe to notifications on a characteristic.
 */
int cb_central_subscribe(const char *svc_uuid, const char *chr_uuid);

/**
 * Unsubscribe from notifications.
 */
int cb_central_unsubscribe(const char *svc_uuid, const char *chr_uuid);

/** Deinitialize central. */
void cb_central_deinit(void);

// ============================================================================
// Utility
// ============================================================================

/** Run the main loop (required for CoreBluetooth callbacks on macOS). */
void cb_run_loop_once(uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* CB_HELPER_H */
