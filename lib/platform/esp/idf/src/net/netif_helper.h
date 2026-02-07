/**
 * Network Interface Helper
 *
 * C helper functions to access ESP-IDF esp_netif APIs.
 * Required because esp_netif uses opaque structures that Zig cannot access directly.
 *
 * Also handles IP_EVENT events (got_ip, lost_ip, etc.)
 */

#ifndef NETIF_HELPER_H
#define NETIF_HELPER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Event Types
// ============================================================================

// Net event types
#define NET_EVT_DHCP_BOUND      1   // DHCP lease acquired
#define NET_EVT_DHCP_RENEWED    2   // DHCP lease renewed (IP didn't change)
#define NET_EVT_IP_LOST         3   // IP lost
#define NET_EVT_STATIC_IP_SET   4   // Static IP configured
#define NET_EVT_AP_STA_ASSIGNED 5   // AP mode: assigned IP to a station

/**
 * DHCP bound event data (full IP configuration)
 */
typedef struct {
    char interface[16];     // Interface name
    uint8_t ip[4];          // IP address
    uint8_t netmask[4];     // Netmask
    uint8_t gateway[4];     // Gateway
    uint8_t dns_main[4];    // Primary DNS
    uint8_t dns_backup[4];  // Secondary DNS
    uint32_t lease_time;    // Lease time in seconds (0 if unknown)
} net_evt_dhcp_bound_t;

/**
 * IP lost event data
 */
typedef struct {
    char interface[16];     // Interface name
} net_evt_ip_lost_t;

/**
 * AP STA assigned event data
 */
typedef struct {
    uint8_t mac[6];         // Station MAC address
    uint8_t ip[4];          // Assigned IP address
} net_evt_ap_sta_assigned_t;

/**
 * Net event structure (union of all event types)
 */
typedef struct {
    int type;               // NET_EVT_*
    union {
        net_evt_dhcp_bound_t dhcp_bound;
        net_evt_ip_lost_t ip_lost;
        net_evt_ap_sta_assigned_t ap_sta_assigned;
    } data;
} net_event_t;

// ============================================================================
// Network interface info structure (Zig-compatible)
// ============================================================================

typedef struct {
    char name[16];
    uint8_t name_len;
    uint8_t mac[6];
    uint8_t state;      // 0=down, 1=up, 2=connected
    uint8_t dhcp;       // 0=disabled, 1=client, 2=server
    uint8_t ip[4];
    uint8_t netmask[4];
    uint8_t gateway[4];
    uint8_t dns_main[4];
    uint8_t dns_backup[4];
} netif_info_t;

// ============================================================================
// Initialization Functions
// ============================================================================

/**
 * Initialize the netif subsystem (esp_netif_init)
 * Must be called before creating any network interfaces.
 * Requires event loop to be initialized first.
 * Returns 0 on success
 */
int netif_helper_init(void);

/**
 * Create default WiFi STA network interface
 * Returns 0 on success
 */
int netif_helper_create_wifi_sta(void);

/**
 * Create default WiFi AP network interface
 * Returns 0 on success
 */
int netif_helper_create_wifi_ap(void);

// ============================================================================
// Query Functions
// ============================================================================

/**
 * Get number of registered network interfaces
 */
int netif_helper_count(void);

/**
 * Get interface name by index
 * Returns name length, 0 if index out of range
 */
int netif_helper_get_name(int index, char* name_buf, int buf_len);

/**
 * Get interface info by name
 * Returns 0 on success, -1 if not found
 */
int netif_helper_get_info(const char* name, netif_info_t* info);

/**
 * Get default interface name
 * Returns name length, 0 if no default
 */
int netif_helper_get_default(char* name_buf, int buf_len);

/**
 * Set default interface by name
 */
void netif_helper_set_default(const char* name);

/**
 * Bring interface up
 */
void netif_helper_up(const char* name);

/**
 * Bring interface down
 */
void netif_helper_down(const char* name);

/**
 * Get DNS servers
 */
void netif_helper_get_dns(uint8_t* primary, uint8_t* secondary);

/**
 * Set DNS servers
 */
void netif_helper_set_dns(const uint8_t* primary, const uint8_t* secondary);

// ============================================================================
// Static IP Configuration
// ============================================================================

/**
 * Set static IP on interface (disables DHCP client)
 * Returns 0 on success
 */
int netif_helper_set_static_ip(const char* name, const uint8_t* ip,
                                const uint8_t* netmask, const uint8_t* gateway);

/**
 * Enable DHCP client on interface
 * Returns 0 on success
 */
int netif_helper_enable_dhcp_client(const char* name);

// ============================================================================
// DHCP Server Functions (for AP mode)
// ============================================================================

/**
 * Configure DHCP server IP range and lease time
 * Returns 0 on success
 */
int netif_helper_configure_dhcps(const char* name, const uint8_t* start_ip,
                                  const uint8_t* end_ip, uint32_t lease_time);

/**
 * Set DHCP server DNS servers
 * Returns 0 on success
 */
int netif_helper_set_dhcps_dns(const char* name, const uint8_t* primary,
                                const uint8_t* secondary);

/**
 * Start DHCP server on interface
 * Returns 0 on success
 */
int netif_helper_start_dhcps(const char* name);

/**
 * Stop DHCP server on interface
 */
void netif_helper_stop_dhcps(const char* name);

// ============================================================================
// Event Functions
// ============================================================================

/**
 * Callback function type for net events
 * Called from ESP-IDF event handler context when IP events occur.
 * 
 * @param ctx User context pointer (passed to init function)
 * @param event Pointer to the event data (valid only during callback)
 */
typedef void (*net_event_callback_t)(void* ctx, const net_event_t* event);

/**
 * Initialize net event system with callback (registers IP_EVENT handlers)
 * Call this after esp_event_loop_create_default() and esp_netif_init()
 * 
 * Events are delivered directly via callback instead of internal queue.
 * 
 * @param callback Function to call when events occur (can be NULL to disable)
 * @param ctx User context pointer passed to callback
 * @return 0 on success, -1 on failure
 */
int netif_helper_event_init_with_callback(net_event_callback_t callback, void* ctx);

/**
 * Initialize net event system (registers IP_EVENT handlers)
 * Call this after esp_event_loop_create_default() and esp_netif_init()
 * 
 * @deprecated Use netif_helper_event_init_with_callback() for direct push
 */
int netif_helper_event_init(void);

/**
 * Poll for net events (non-blocking)
 * Returns true if event available, fills event structure
 * 
 * @deprecated Use callback-based API instead
 */
bool netif_helper_poll_event(net_event_t* event);

#ifdef __cplusplus
}
#endif

#endif // NETIF_HELPER_H
