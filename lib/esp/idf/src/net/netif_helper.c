/**
 * Network Interface Helper Implementation
 *
 * Wraps ESP-IDF esp_netif APIs for Zig access.
 * Also handles IP_EVENT events.
 */

#include "netif_helper.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "esp_log.h"
#include "lwip/ip4_addr.h"
#include <string.h>

// DHCP server lease configuration structure
// This matches the internal ESP-IDF structure for dhcps_option
typedef struct {
    bool enable;
    ip4_addr_t start_ip;
    ip4_addr_t end_ip;
} dhcps_lease_config_t;

static const char* TAG = "net_helper";

// Maximum number of interfaces to track
#define MAX_NETIFS 4

// Cached interface handles
static esp_netif_t* s_netifs[MAX_NETIFS] = {NULL};
static int s_netif_count = 0;

// Event queue for IP events (deprecated, use callback instead)
static QueueHandle_t s_event_queue = NULL;

// Callback for direct event push
static net_event_callback_t s_event_callback = NULL;
static void* s_event_callback_ctx = NULL;

/**
 * Refresh the list of network interfaces
 */
static void refresh_netif_list(void) {
    s_netif_count = 0;
    esp_netif_t* netif = NULL;
    
    while ((netif = esp_netif_next(netif)) != NULL && s_netif_count < MAX_NETIFS) {
        s_netifs[s_netif_count++] = netif;
    }
}

/**
 * Find interface by name
 */
static esp_netif_t* find_netif_by_name(const char* name) {
    // Try common interface keys first
    esp_netif_t* netif = NULL;
    
    if (strcmp(name, "sta") == 0 || strcmp(name, "WIFI_STA_DEF") == 0) {
        netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    } else if (strcmp(name, "ap") == 0 || strcmp(name, "WIFI_AP_DEF") == 0) {
        netif = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    } else if (strcmp(name, "eth") == 0 || strcmp(name, "ETH_DEF") == 0) {
        netif = esp_netif_get_handle_from_ifkey("ETH_DEF");
    } else {
        // Try as-is
        netif = esp_netif_get_handle_from_ifkey(name);
    }
    
    return netif;
}

/**
 * Convert IP address from esp_ip4_addr_t to byte array
 */
static void ip4_to_bytes(const esp_ip4_addr_t* ip, uint8_t* bytes) {
    uint32_t addr = ip->addr;
    bytes[0] = (addr >> 0) & 0xFF;
    bytes[1] = (addr >> 8) & 0xFF;
    bytes[2] = (addr >> 16) & 0xFF;
    bytes[3] = (addr >> 24) & 0xFF;
}

/**
 * Convert byte array to esp_ip4_addr_t
 */
static void bytes_to_ip4(const uint8_t* bytes, esp_ip4_addr_t* ip) {
    ip->addr = ((uint32_t)bytes[0] << 0) |
               ((uint32_t)bytes[1] << 8) |
               ((uint32_t)bytes[2] << 16) |
               ((uint32_t)bytes[3] << 24);
}

// ============================================================================
// Initialization Functions
// ============================================================================

static bool s_netif_initialized = false;

int netif_helper_init(void) {
    if (s_netif_initialized) {
        ESP_LOGD(TAG, "netif already initialized");
        return 0;
    }

    esp_err_t ret = esp_netif_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "esp_netif_init failed: %s", esp_err_to_name(ret));
        return -1;
    }

    s_netif_initialized = true;
    ESP_LOGI(TAG, "netif subsystem initialized");
    return 0;
}

int netif_helper_create_wifi_sta(void) {
    esp_netif_t* netif = esp_netif_create_default_wifi_sta();
    if (netif == NULL) {
        ESP_LOGE(TAG, "Failed to create WiFi STA netif");
        return -1;
    }
    ESP_LOGI(TAG, "WiFi STA netif created");
    return 0;
}

int netif_helper_create_wifi_ap(void) {
    esp_netif_t* netif = esp_netif_create_default_wifi_ap();
    if (netif == NULL) {
        ESP_LOGE(TAG, "Failed to create WiFi AP netif");
        return -1;
    }
    ESP_LOGI(TAG, "WiFi AP netif created");
    return 0;
}

// ============================================================================
// Query Functions
// ============================================================================

int netif_helper_count(void) {
    refresh_netif_list();
    return s_netif_count;
}

int netif_helper_get_name(int index, char* name_buf, int buf_len) {
    refresh_netif_list();
    
    if (index < 0 || index >= s_netif_count || buf_len < 1) {
        return 0;
    }
    
    const char* desc = esp_netif_get_desc(s_netifs[index]);
    if (desc == NULL) {
        // Use interface key as fallback
        const char* key = esp_netif_get_ifkey(s_netifs[index]);
        if (key == NULL) {
            name_buf[0] = '\0';
            return 0;
        }
        
        // Simplify common names
        if (strcmp(key, "WIFI_STA_DEF") == 0) {
            strncpy(name_buf, "sta", buf_len - 1);
        } else if (strcmp(key, "WIFI_AP_DEF") == 0) {
            strncpy(name_buf, "ap", buf_len - 1);
        } else if (strcmp(key, "ETH_DEF") == 0) {
            strncpy(name_buf, "eth", buf_len - 1);
        } else {
            strncpy(name_buf, key, buf_len - 1);
        }
    } else {
        strncpy(name_buf, desc, buf_len - 1);
    }
    
    name_buf[buf_len - 1] = '\0';
    return strlen(name_buf);
}

int netif_helper_get_info(const char* name, netif_info_t* info) {
    if (name == NULL || info == NULL) {
        return -1;
    }
    
    esp_netif_t* netif = find_netif_by_name(name);
    if (netif == NULL) {
        return -1;
    }
    
    memset(info, 0, sizeof(netif_info_t));
    
    // Name
    strncpy(info->name, name, sizeof(info->name) - 1);
    info->name_len = strlen(info->name);
    
    // MAC address
    esp_netif_get_mac(netif, info->mac);
    
    // State
    if (!esp_netif_is_netif_up(netif)) {
        info->state = 0; // down
    } else {
        // Check if we have an IP
        esp_netif_ip_info_t ip_info;
        if (esp_netif_get_ip_info(netif, &ip_info) == ESP_OK && ip_info.ip.addr != 0) {
            info->state = 2; // connected
        } else {
            info->state = 1; // up
        }
    }
    
    // DHCP mode
    esp_netif_dhcp_status_t dhcp_status;
    if (esp_netif_dhcpc_get_status(netif, &dhcp_status) == ESP_OK) {
        if (dhcp_status == ESP_NETIF_DHCP_STARTED || dhcp_status == ESP_NETIF_DHCP_STOPPED) {
            info->dhcp = 1; // client
        }
    }
    if (esp_netif_dhcps_get_status(netif, &dhcp_status) == ESP_OK) {
        if (dhcp_status == ESP_NETIF_DHCP_STARTED) {
            info->dhcp = 2; // server
        }
    }
    
    // IP info
    esp_netif_ip_info_t ip_info;
    if (esp_netif_get_ip_info(netif, &ip_info) == ESP_OK) {
        ip4_to_bytes(&ip_info.ip, info->ip);
        ip4_to_bytes(&ip_info.netmask, info->netmask);
        ip4_to_bytes(&ip_info.gw, info->gateway);
    }
    
    // DNS servers
    esp_netif_dns_info_t dns_info;
    if (esp_netif_get_dns_info(netif, ESP_NETIF_DNS_MAIN, &dns_info) == ESP_OK) {
        ip4_to_bytes(&dns_info.ip.u_addr.ip4, info->dns_main);
    }
    if (esp_netif_get_dns_info(netif, ESP_NETIF_DNS_BACKUP, &dns_info) == ESP_OK) {
        ip4_to_bytes(&dns_info.ip.u_addr.ip4, info->dns_backup);
    }
    
    return 0;
}

int netif_helper_get_default(char* name_buf, int buf_len) {
    if (name_buf == NULL || buf_len < 1) {
        return 0;
    }
    
    esp_netif_t* netif = esp_netif_get_default_netif();
    if (netif == NULL) {
        return 0;
    }
    
    const char* key = esp_netif_get_ifkey(netif);
    if (key == NULL) {
        return 0;
    }
    
    // Simplify common names
    if (strcmp(key, "WIFI_STA_DEF") == 0) {
        strncpy(name_buf, "sta", buf_len - 1);
    } else if (strcmp(key, "WIFI_AP_DEF") == 0) {
        strncpy(name_buf, "ap", buf_len - 1);
    } else if (strcmp(key, "ETH_DEF") == 0) {
        strncpy(name_buf, "eth", buf_len - 1);
    } else {
        strncpy(name_buf, key, buf_len - 1);
    }
    
    name_buf[buf_len - 1] = '\0';
    return strlen(name_buf);
}

void netif_helper_set_default(const char* name) {
    if (name == NULL) {
        return;
    }
    
    esp_netif_t* netif = find_netif_by_name(name);
    if (netif != NULL) {
        esp_netif_set_default_netif(netif);
    }
}

void netif_helper_up(const char* name) {
    if (name == NULL) {
        return;
    }
    
    esp_netif_t* netif = find_netif_by_name(name);
    if (netif != NULL) {
        esp_netif_action_start(netif, NULL, 0, NULL);
    }
}

void netif_helper_down(const char* name) {
    if (name == NULL) {
        return;
    }
    
    esp_netif_t* netif = find_netif_by_name(name);
    if (netif != NULL) {
        esp_netif_action_stop(netif, NULL, 0, NULL);
    }
}

void netif_helper_get_dns(uint8_t* primary, uint8_t* secondary) {
    if (primary == NULL || secondary == NULL) {
        return;
    }
    
    memset(primary, 0, 4);
    memset(secondary, 0, 4);
    
    // Get DNS from default interface
    esp_netif_t* netif = esp_netif_get_default_netif();
    if (netif == NULL) {
        // Try WiFi STA as fallback
        netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    }
    
    if (netif == NULL) {
        return;
    }
    
    esp_netif_dns_info_t dns_info;
    if (esp_netif_get_dns_info(netif, ESP_NETIF_DNS_MAIN, &dns_info) == ESP_OK) {
        ip4_to_bytes(&dns_info.ip.u_addr.ip4, primary);
    }
    if (esp_netif_get_dns_info(netif, ESP_NETIF_DNS_BACKUP, &dns_info) == ESP_OK) {
        ip4_to_bytes(&dns_info.ip.u_addr.ip4, secondary);
    }
}

void netif_helper_set_dns(const uint8_t* primary, const uint8_t* secondary) {
    if (primary == NULL) {
        return;
    }
    
    // Set DNS on default interface
    esp_netif_t* netif = esp_netif_get_default_netif();
    if (netif == NULL) {
        netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    }
    
    if (netif == NULL) {
        return;
    }
    
    esp_netif_dns_info_t dns_info;
    dns_info.ip.type = ESP_IPADDR_TYPE_V4;
    
    // Primary DNS
    bytes_to_ip4(primary, &dns_info.ip.u_addr.ip4);
    esp_netif_set_dns_info(netif, ESP_NETIF_DNS_MAIN, &dns_info);
    
    // Secondary DNS
    if (secondary != NULL && (secondary[0] != 0 || secondary[1] != 0 || secondary[2] != 0 || secondary[3] != 0)) {
        bytes_to_ip4(secondary, &dns_info.ip.u_addr.ip4);
        esp_netif_set_dns_info(netif, ESP_NETIF_DNS_BACKUP, &dns_info);
    }
}

// ============================================================================
// Static IP Configuration
// ============================================================================

int netif_helper_set_static_ip(const char* name, const uint8_t* ip,
                                const uint8_t* netmask, const uint8_t* gateway) {
    if (name == NULL || ip == NULL || netmask == NULL || gateway == NULL) {
        return -1;
    }
    
    esp_netif_t* netif = find_netif_by_name(name);
    if (netif == NULL) {
        return -1;
    }
    
    // Stop DHCP client first
    esp_netif_dhcpc_stop(netif);
    
    // Set static IP
    esp_netif_ip_info_t ip_info;
    bytes_to_ip4(ip, &ip_info.ip);
    bytes_to_ip4(netmask, &ip_info.netmask);
    bytes_to_ip4(gateway, &ip_info.gw);
    
    esp_err_t ret = esp_netif_set_ip_info(netif, &ip_info);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to set static IP: %s", esp_err_to_name(ret));
        return -1;
    }
    
    ESP_LOGI(TAG, "Static IP set on %s: %d.%d.%d.%d", name, ip[0], ip[1], ip[2], ip[3]);
    return 0;
}

int netif_helper_enable_dhcp_client(const char* name) {
    if (name == NULL) {
        return -1;
    }
    
    esp_netif_t* netif = find_netif_by_name(name);
    if (netif == NULL) {
        return -1;
    }
    
    esp_err_t ret = esp_netif_dhcpc_start(netif);
    if (ret != ESP_OK && ret != ESP_ERR_ESP_NETIF_DHCP_ALREADY_STARTED) {
        ESP_LOGE(TAG, "Failed to start DHCP client: %s", esp_err_to_name(ret));
        return -1;
    }
    
    ESP_LOGI(TAG, "DHCP client enabled on %s", name);
    return 0;
}

// ============================================================================
// DHCP Server Functions
// ============================================================================

int netif_helper_configure_dhcps(const char* name, const uint8_t* start_ip,
                                  const uint8_t* end_ip, uint32_t lease_time) {
    if (name == NULL || start_ip == NULL || end_ip == NULL) {
        return -1;
    }
    
    esp_netif_t* netif = find_netif_by_name(name);
    if (netif == NULL) {
        ESP_LOGE(TAG, "Interface not found: %s", name);
        return -1;
    }
    
    // Stop DHCP server if running
    esp_netif_dhcps_stop(netif);
    
    // Configure IP range
    dhcps_lease_config_t lease;
    lease.enable = true;
    
    // Convert byte array to ip4_addr_t
    lease.start_ip.addr = ((uint32_t)start_ip[0] << 0) |
                          ((uint32_t)start_ip[1] << 8) |
                          ((uint32_t)start_ip[2] << 16) |
                          ((uint32_t)start_ip[3] << 24);
    lease.end_ip.addr = ((uint32_t)end_ip[0] << 0) |
                        ((uint32_t)end_ip[1] << 8) |
                        ((uint32_t)end_ip[2] << 16) |
                        ((uint32_t)end_ip[3] << 24);
    
    esp_err_t ret = esp_netif_dhcps_option(netif, ESP_NETIF_OP_SET, 
                                           ESP_NETIF_REQUESTED_IP_ADDRESS, 
                                           &lease, sizeof(lease));
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to set DHCP lease range: %s", esp_err_to_name(ret));
        return -1;
    }
    
    // Set lease time (in minutes)
    uint32_t lease_time_min = lease_time / 60;
    if (lease_time_min < 1) lease_time_min = 1;
    
    ret = esp_netif_dhcps_option(netif, ESP_NETIF_OP_SET,
                                  ESP_NETIF_IP_ADDRESS_LEASE_TIME,
                                  &lease_time_min, sizeof(lease_time_min));
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to set lease time: %s", esp_err_to_name(ret));
    }
    
    ESP_LOGI(TAG, "DHCP server configured on %s: %d.%d.%d.%d - %d.%d.%d.%d",
             name, start_ip[0], start_ip[1], start_ip[2], start_ip[3],
             end_ip[0], end_ip[1], end_ip[2], end_ip[3]);
    return 0;
}

int netif_helper_set_dhcps_dns(const char* name, const uint8_t* primary,
                                const uint8_t* secondary) {
    if (name == NULL || primary == NULL) {
        return -1;
    }
    
    esp_netif_t* netif = find_netif_by_name(name);
    if (netif == NULL) {
        return -1;
    }
    
    // Set DNS for DHCP server to advertise
    esp_netif_dns_info_t dns_info;
    dns_info.ip.type = ESP_IPADDR_TYPE_V4;
    
    bytes_to_ip4(primary, &dns_info.ip.u_addr.ip4);
    esp_err_t ret = esp_netif_set_dns_info(netif, ESP_NETIF_DNS_MAIN, &dns_info);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to set DHCPS DNS: %s", esp_err_to_name(ret));
        return -1;
    }
    
    if (secondary != NULL && (secondary[0] != 0 || secondary[1] != 0 || secondary[2] != 0 || secondary[3] != 0)) {
        bytes_to_ip4(secondary, &dns_info.ip.u_addr.ip4);
        esp_netif_set_dns_info(netif, ESP_NETIF_DNS_BACKUP, &dns_info);
    }
    
    return 0;
}

int netif_helper_start_dhcps(const char* name) {
    if (name == NULL) {
        return -1;
    }
    
    esp_netif_t* netif = find_netif_by_name(name);
    if (netif == NULL) {
        return -1;
    }
    
    esp_err_t ret = esp_netif_dhcps_start(netif);
    if (ret != ESP_OK && ret != ESP_ERR_ESP_NETIF_DHCP_ALREADY_STARTED) {
        ESP_LOGE(TAG, "Failed to start DHCP server: %s", esp_err_to_name(ret));
        return -1;
    }
    
    ESP_LOGI(TAG, "DHCP server started on %s", name);
    return 0;
}

void netif_helper_stop_dhcps(const char* name) {
    if (name == NULL) {
        return;
    }
    
    esp_netif_t* netif = find_netif_by_name(name);
    if (netif != NULL) {
        esp_netif_dhcps_stop(netif);
        ESP_LOGI(TAG, "DHCP server stopped on %s", name);
    }
}

// ============================================================================
// IP Event Handling
// ============================================================================

/**
 * Get interface name from esp_netif handle
 */
static void get_interface_name(esp_netif_t* netif, char* name_buf, size_t buf_len) {
    if (netif == NULL || name_buf == NULL || buf_len < 1) {
        if (name_buf && buf_len > 0) name_buf[0] = '\0';
        return;
    }
    
    const char* key = esp_netif_get_ifkey(netif);
    if (key == NULL) {
        name_buf[0] = '\0';
        return;
    }
    
    // Simplify common names
    if (strcmp(key, "WIFI_STA_DEF") == 0) {
        strncpy(name_buf, "sta", buf_len - 1);
    } else if (strcmp(key, "WIFI_AP_DEF") == 0) {
        strncpy(name_buf, "ap", buf_len - 1);
    } else if (strcmp(key, "ETH_DEF") == 0) {
        strncpy(name_buf, "eth", buf_len - 1);
    } else {
        strncpy(name_buf, key, buf_len - 1);
    }
    name_buf[buf_len - 1] = '\0';
}

/**
 * Send event via callback or queue
 */
static void send_event(const net_event_t* evt) {
    if (s_event_callback != NULL) {
        // Direct callback (preferred)
        s_event_callback(s_event_callback_ctx, evt);
    } else if (s_event_queue != NULL) {
        // Legacy queue-based (deprecated)
        xQueueSend(s_event_queue, evt, 0);
    }
}

/**
 * IP event handler
 */
static void ip_event_handler(void* arg, esp_event_base_t event_base,
                             int32_t event_id, void* event_data) {
    (void)arg;
    
    ESP_LOGD(TAG, "ip_event_handler called: event_id=%ld, callback=%p, queue=%p", 
             event_id, (void*)s_event_callback, (void*)s_event_queue);
    
    if (event_base != IP_EVENT) {
        ESP_LOGW(TAG, "Ignoring event: base=%s", event_base);
        return;
    }
    
    // Must have either callback or queue
    if (s_event_callback == NULL && s_event_queue == NULL) {
        ESP_LOGW(TAG, "No callback or queue configured");
        return;
    }
    
    net_event_t evt;
    memset(&evt, 0, sizeof(evt));
    
    switch (event_id) {
        case IP_EVENT_STA_GOT_IP: {
            ESP_LOGI(TAG, "GOT_IP event");
            ip_event_got_ip_t* got_ip = (ip_event_got_ip_t*)event_data;
            
            evt.type = got_ip->ip_changed ? NET_EVT_DHCP_BOUND : NET_EVT_DHCP_RENEWED;
            
            get_interface_name(got_ip->esp_netif, evt.data.dhcp_bound.interface, 
                               sizeof(evt.data.dhcp_bound.interface));
            
            ip4_to_bytes(&got_ip->ip_info.ip, evt.data.dhcp_bound.ip);
            ip4_to_bytes(&got_ip->ip_info.netmask, evt.data.dhcp_bound.netmask);
            ip4_to_bytes(&got_ip->ip_info.gw, evt.data.dhcp_bound.gateway);
            
            // Get DNS from interface
            esp_netif_dns_info_t dns_info;
            if (esp_netif_get_dns_info(got_ip->esp_netif, ESP_NETIF_DNS_MAIN, &dns_info) == ESP_OK) {
                ip4_to_bytes(&dns_info.ip.u_addr.ip4, evt.data.dhcp_bound.dns_main);
            }
            if (esp_netif_get_dns_info(got_ip->esp_netif, ESP_NETIF_DNS_BACKUP, &dns_info) == ESP_OK) {
                ip4_to_bytes(&dns_info.ip.u_addr.ip4, evt.data.dhcp_bound.dns_backup);
            }
            
            // Lease time not directly available, set to 0
            evt.data.dhcp_bound.lease_time = 0;
            
            send_event(&evt);
            break;
        }
        
        case IP_EVENT_STA_LOST_IP: {
            evt.type = NET_EVT_IP_LOST;
            strncpy(evt.data.ip_lost.interface, "sta", sizeof(evt.data.ip_lost.interface) - 1);
            send_event(&evt);
            break;
        }
        
        case IP_EVENT_AP_STAIPASSIGNED: {
            ip_event_ap_staipassigned_t* assigned = (ip_event_ap_staipassigned_t*)event_data;
            
            evt.type = NET_EVT_AP_STA_ASSIGNED;
            memcpy(evt.data.ap_sta_assigned.mac, assigned->mac, 6);
            ip4_to_bytes(&assigned->ip, evt.data.ap_sta_assigned.ip);
            
            send_event(&evt);
            break;
        }
        
        case IP_EVENT_ETH_GOT_IP: {
            ip_event_got_ip_t* got_ip = (ip_event_got_ip_t*)event_data;
            
            evt.type = got_ip->ip_changed ? NET_EVT_DHCP_BOUND : NET_EVT_DHCP_RENEWED;
            
            get_interface_name(got_ip->esp_netif, evt.data.dhcp_bound.interface,
                               sizeof(evt.data.dhcp_bound.interface));
            
            ip4_to_bytes(&got_ip->ip_info.ip, evt.data.dhcp_bound.ip);
            ip4_to_bytes(&got_ip->ip_info.netmask, evt.data.dhcp_bound.netmask);
            ip4_to_bytes(&got_ip->ip_info.gw, evt.data.dhcp_bound.gateway);
            
            send_event(&evt);
            break;
        }
        
        case IP_EVENT_ETH_LOST_IP: {
            evt.type = NET_EVT_IP_LOST;
            strncpy(evt.data.ip_lost.interface, "eth", sizeof(evt.data.ip_lost.interface) - 1);
            send_event(&evt);
            break;
        }
        
        default:
            break;
    }
}

/**
 * Register IP event handlers (shared by both init functions)
 */
static int register_ip_handlers(void) {
    esp_err_t ret;
    ret = esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                        &ip_event_handler, NULL, NULL);
    ESP_LOGI(TAG, "Registered GOT_IP handler: ret=%d", ret);
    
    ret = esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_LOST_IP,
                                        &ip_event_handler, NULL, NULL);
    ESP_LOGI(TAG, "Registered LOST_IP handler: ret=%d", ret);
    
    ret = esp_event_handler_instance_register(IP_EVENT, IP_EVENT_AP_STAIPASSIGNED,
                                        &ip_event_handler, NULL, NULL);
    ESP_LOGI(TAG, "Registered AP_STAIPASSIGNED handler: ret=%d", ret);
    
    ret = esp_event_handler_instance_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                        &ip_event_handler, NULL, NULL);
    ret = esp_event_handler_instance_register(IP_EVENT, IP_EVENT_ETH_LOST_IP,
                                        &ip_event_handler, NULL, NULL);
    
    ESP_LOGI(TAG, "All handlers registered");
    return 0;
}

int netif_helper_event_init_with_callback(net_event_callback_t callback, void* ctx) {
    ESP_LOGI(TAG, "netif_helper_event_init_with_callback called, callback=%p", (void*)callback);
    
    // Check if already initialized with callback
    if (s_event_callback != NULL) {
        ESP_LOGI(TAG, "Already initialized with callback");
        return 0;
    }
    
    // Store callback
    s_event_callback = callback;
    s_event_callback_ctx = ctx;
    
    // Register handlers
    return register_ip_handlers();
}

int netif_helper_event_init(void) {
    ESP_LOGW(TAG, "netif_helper_event_init() is deprecated. Use netif_helper_event_init_with_callback() instead.");
    ESP_LOGI(TAG, "netif_helper_event_init called, queue=%p", (void*)s_event_queue);
    
    if (s_event_queue != NULL || s_event_callback != NULL) {
        // Already initialized
        ESP_LOGI(TAG, "Already initialized");
        return 0;
    }
    
    // Note: Event loop must be initialized before calling this function
    // Use idf/event.init() to ensure event loop exists
    
    // Create event queue (deprecated path)
    s_event_queue = xQueueCreate(8, sizeof(net_event_t));
    if (s_event_queue == NULL) {
        ESP_LOGE(TAG, "Failed to create event queue");
        return -1;
    }
    
    ESP_LOGI(TAG, "Event queue created: %p", (void*)s_event_queue);
    
    // Register handlers
    return register_ip_handlers();
}

bool netif_helper_poll_event(net_event_t* event) {
    // This function is deprecated - use callback-based API instead
    if (s_event_callback != NULL) {
        ESP_LOGW(TAG, "poll_event() called but callback is registered - events go to callback, not queue");
    }
    if (s_event_queue == NULL || event == NULL) {
        return false;
    }
    
    return xQueueReceive(s_event_queue, event, 0) == pdTRUE;
}
