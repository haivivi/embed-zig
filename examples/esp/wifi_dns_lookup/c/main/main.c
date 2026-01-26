/**
 * WiFi DNS Lookup - C Version
 * 
 * Tests DNS resolution using UDP, TCP, and HTTPS (DoH) protocols
 * Uses lwip sockets for UDP/TCP and esp_http_client for DoH
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_system.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "nvs_flash.h"
#include "esp_http_client.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_crt_bundle.h"
#include "lwip/sockets.h"
#include "lwip/netdb.h"
#include "sdkconfig.h"

static const char *TAG = "dns_lookup";
static const char *BUILD_TAG = "wifi_dns_lookup_c_v1";

// WiFi event group
static EventGroupHandle_t s_wifi_event_group;
#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAIL_BIT      BIT1

static int s_retry_num = 0;
#define MAX_RETRY 5

// Test domains
static const char *test_domains[] = {
    "www.google.com",
    "www.baidu.com",
    "cloudflare.com",
    "github.com",
};
#define NUM_TEST_DOMAINS (sizeof(test_domains) / sizeof(test_domains[0]))

// ============================================================================
// Memory Statistics
// ============================================================================

static void print_memory_stats(void) {
    ESP_LOGI(TAG, "=== Heap Memory Statistics ===");
    
    // Internal DRAM
    size_t internal_total = heap_caps_get_total_size(MALLOC_CAP_INTERNAL);
    size_t internal_free = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    ESP_LOGI(TAG, "Internal DRAM: Total=%u Free=%u Used=%u",
             internal_total, internal_free, internal_total - internal_free);
    
    // External PSRAM
    size_t psram_total = heap_caps_get_total_size(MALLOC_CAP_SPIRAM);
    size_t psram_free = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    if (psram_total > 0) {
        ESP_LOGI(TAG, "External PSRAM: Total=%u Free=%u Used=%u",
                 psram_total, psram_free, psram_total - psram_free);
    }
}

// ============================================================================
// WiFi
// ============================================================================

static void event_handler(void* arg, esp_event_base_t event_base,
                          int32_t event_id, void* event_data)
{
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        if (s_retry_num < MAX_RETRY) {
            esp_wifi_connect();
            s_retry_num++;
            ESP_LOGI(TAG, "Retry connecting to WiFi... (%d/%d)", s_retry_num, MAX_RETRY);
        } else {
            xEventGroupSetBits(s_wifi_event_group, WIFI_FAIL_BIT);
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* event = (ip_event_got_ip_t*) event_data;
        ESP_LOGI(TAG, "Connected! IP: " IPSTR, IP2STR(&event->ip_info.ip));
        s_retry_num = 0;
        xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
    }
}

static esp_err_t wifi_init_sta(void)
{
    s_wifi_event_group = xEventGroupCreate();

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    esp_event_handler_instance_t instance_any_id;
    esp_event_handler_instance_t instance_got_ip;
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT,
                                                        ESP_EVENT_ANY_ID,
                                                        &event_handler,
                                                        NULL,
                                                        &instance_any_id));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT,
                                                        IP_EVENT_STA_GOT_IP,
                                                        &event_handler,
                                                        NULL,
                                                        &instance_got_ip));

    wifi_config_t wifi_config = {
        .sta = {
            .ssid = CONFIG_WIFI_SSID,
            .password = CONFIG_WIFI_PASSWORD,
            .threshold.authmode = WIFI_AUTH_WPA2_PSK,
        },
    };
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "Connecting to SSID: %s", CONFIG_WIFI_SSID);

    // Wait for connection
    EventBits_t bits = xEventGroupWaitBits(s_wifi_event_group,
            WIFI_CONNECTED_BIT | WIFI_FAIL_BIT,
            pdFALSE, pdFALSE, pdMS_TO_TICKS(30000));

    if (bits & WIFI_CONNECTED_BIT) {
        return ESP_OK;
    } else if (bits & WIFI_FAIL_BIT) {
        ESP_LOGE(TAG, "Failed to connect to WiFi");
        return ESP_FAIL;
    } else {
        ESP_LOGE(TAG, "WiFi connection timeout");
        return ESP_ERR_TIMEOUT;
    }
}

// ============================================================================
// DNS Protocol Helpers
// ============================================================================

// Build DNS query packet
static int build_dns_query(uint8_t *buf, const char *hostname, uint16_t tx_id) {
    int pos = 0;
    
    // Transaction ID
    buf[pos++] = (tx_id >> 8) & 0xFF;
    buf[pos++] = tx_id & 0xFF;
    
    // Flags: standard query, recursion desired
    buf[pos++] = 0x01;
    buf[pos++] = 0x00;
    
    // Questions: 1
    buf[pos++] = 0x00;
    buf[pos++] = 0x01;
    
    // Answer RRs: 0
    buf[pos++] = 0x00;
    buf[pos++] = 0x00;
    
    // Authority RRs: 0
    buf[pos++] = 0x00;
    buf[pos++] = 0x00;
    
    // Additional RRs: 0
    buf[pos++] = 0x00;
    buf[pos++] = 0x00;
    
    // Question section: encode hostname
    // "www.google.com" -> "\x03www\x06google\x03com\x00"
    int label_start = pos;
    pos++; // reserve space for label length
    
    for (const char *p = hostname; *p; p++) {
        if (*p == '.') {
            buf[label_start] = pos - label_start - 1;
            label_start = pos;
            pos++;
        } else {
            buf[pos++] = *p;
        }
    }
    // Last label
    buf[label_start] = pos - label_start - 1;
    buf[pos++] = 0x00; // null terminator
    
    // Type: A (1)
    buf[pos++] = 0x00;
    buf[pos++] = 0x01;
    
    // Class: IN (1)
    buf[pos++] = 0x00;
    buf[pos++] = 0x01;
    
    return pos;
}

// Parse DNS response and extract first A record
static int parse_dns_response(const uint8_t *data, int len, uint8_t *ip_out) {
    if (len < 12) return -1;
    
    // Check response code (lower 4 bits of byte 3)
    uint8_t rcode = data[3] & 0x0F;
    if (rcode != 0) return -1;
    
    // Get answer count
    uint16_t answer_count = (data[6] << 8) | data[7];
    if (answer_count == 0) return -1;
    
    // Skip header (12 bytes)
    int pos = 12;
    
    // Skip question section
    while (pos < len && data[pos] != 0) {
        if ((data[pos] & 0xC0) == 0xC0) {
            // Compression pointer
            pos += 2;
            break;
        }
        pos += data[pos] + 1;
    }
    if (pos < len && data[pos] == 0) pos++;
    pos += 4; // Skip QTYPE and QCLASS
    
    // Parse answers
    for (int i = 0; i < answer_count && pos + 12 <= len; i++) {
        // Skip name (handle compression)
        if ((data[pos] & 0xC0) == 0xC0) {
            pos += 2;
        } else {
            while (pos < len && data[pos] != 0) {
                pos += data[pos] + 1;
            }
            pos++;
        }
        
        if (pos + 10 > len) break;
        
        uint16_t rtype = (data[pos] << 8) | data[pos + 1];
        pos += 2;
        // Skip class
        pos += 2;
        // Skip TTL
        pos += 4;
        uint16_t rdlength = (data[pos] << 8) | data[pos + 1];
        pos += 2;
        
        // Type A (1) with 4-byte address
        if (rtype == 1 && rdlength == 4 && pos + 4 <= len) {
            ip_out[0] = data[pos];
            ip_out[1] = data[pos + 1];
            ip_out[2] = data[pos + 2];
            ip_out[3] = data[pos + 3];
            return 0;
        }
        
        pos += rdlength;
    }
    
    return -1;
}

// ============================================================================
// DNS Resolution Functions
// ============================================================================

// UDP DNS resolution
static int dns_resolve_udp(const char *hostname, uint32_t server_ip, uint8_t *ip_out) {
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) {
        ESP_LOGE(TAG, "Failed to create UDP socket");
        return -1;
    }
    
    // Set timeout
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    
    // Build query
    uint8_t query[512];
    static uint16_t tx_id = 0x1234;
    int query_len = build_dns_query(query, hostname, tx_id++);
    
    // Send query
    struct sockaddr_in dest = {
        .sin_family = AF_INET,
        .sin_port = htons(53),
        .sin_addr.s_addr = server_ip,
    };
    
    if (sendto(sock, query, query_len, 0, (struct sockaddr *)&dest, sizeof(dest)) < 0) {
        ESP_LOGE(TAG, "Failed to send DNS query");
        close(sock);
        return -1;
    }
    
    // Receive response
    uint8_t response[512];
    int response_len = recvfrom(sock, response, sizeof(response), 0, NULL, NULL);
    close(sock);
    
    if (response_len < 0) {
        ESP_LOGE(TAG, "Failed to receive DNS response (timeout?)");
        return -1;
    }
    
    // Parse response
    return parse_dns_response(response, response_len, ip_out);
}

// TCP DNS resolution
static int dns_resolve_tcp(const char *hostname, uint32_t server_ip, uint8_t *ip_out) {
    int sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock < 0) {
        ESP_LOGE(TAG, "Failed to create TCP socket");
        return -1;
    }
    
    // Set timeout
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    
    // Connect
    struct sockaddr_in dest = {
        .sin_family = AF_INET,
        .sin_port = htons(53),
        .sin_addr.s_addr = server_ip,
    };
    
    if (connect(sock, (struct sockaddr *)&dest, sizeof(dest)) < 0) {
        ESP_LOGE(TAG, "Failed to connect to DNS server");
        close(sock);
        return -1;
    }
    
    // Build query
    uint8_t query[514]; // 2 bytes length prefix + 512 query
    static uint16_t tx_id = 0x5678;
    int query_len = build_dns_query(query + 2, hostname, tx_id++);
    
    // TCP DNS: prepend 2-byte length
    query[0] = (query_len >> 8) & 0xFF;
    query[1] = query_len & 0xFF;
    
    // Send query
    if (send(sock, query, query_len + 2, 0) < 0) {
        ESP_LOGE(TAG, "Failed to send DNS query");
        close(sock);
        return -1;
    }
    
    // Receive length prefix
    uint8_t len_buf[2];
    if (recv(sock, len_buf, 2, 0) != 2) {
        ESP_LOGE(TAG, "Failed to receive response length");
        close(sock);
        return -1;
    }
    int response_len = (len_buf[0] << 8) | len_buf[1];
    
    // Receive response
    uint8_t response[512];
    if (response_len > sizeof(response)) {
        ESP_LOGE(TAG, "Response too large");
        close(sock);
        return -1;
    }
    
    int total_read = 0;
    while (total_read < response_len) {
        int n = recv(sock, response + total_read, response_len - total_read, 0);
        if (n <= 0) break;
        total_read += n;
    }
    close(sock);
    
    // Parse response
    return parse_dns_response(response, total_read, ip_out);
}

// DoH (DNS over HTTPS) context
typedef struct {
    uint8_t *response_buf;
    int response_len;
    int max_len;
} doh_ctx_t;

static esp_err_t doh_event_handler(esp_http_client_event_t *evt) {
    doh_ctx_t *ctx = (doh_ctx_t *)evt->user_data;
    
    switch(evt->event_id) {
        case HTTP_EVENT_ON_DATA:
            if (ctx->response_len + evt->data_len <= ctx->max_len) {
                memcpy(ctx->response_buf + ctx->response_len, evt->data, evt->data_len);
                ctx->response_len += evt->data_len;
            }
            break;
        default:
            break;
    }
    return ESP_OK;
}

// HTTPS DNS resolution (DoH)
static int dns_resolve_https(const char *hostname, const char *doh_host, uint8_t *ip_out) {
    // Build DNS query
    uint8_t query[512];
    static uint16_t tx_id = 0x9ABC;
    int query_len = build_dns_query(query, hostname, tx_id++);
    
    // Build DoH URL
    char url[256];
    snprintf(url, sizeof(url), "https://%s/dns-query", doh_host);
    
    // Response buffer
    uint8_t response[1024];
    doh_ctx_t ctx = {
        .response_buf = response,
        .response_len = 0,
        .max_len = sizeof(response),
    };
    
    esp_http_client_config_t config = {
        .url = url,
        .event_handler = doh_event_handler,
        .user_data = &ctx,
        .timeout_ms = 10000,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };
    
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (!client) {
        ESP_LOGE(TAG, "Failed to init HTTP client");
        return -1;
    }
    
    // Set headers for DoH
    esp_http_client_set_method(client, HTTP_METHOD_POST);
    esp_http_client_set_header(client, "Content-Type", "application/dns-message");
    esp_http_client_set_header(client, "Accept", "application/dns-message");
    esp_http_client_set_post_field(client, (const char *)query, query_len);
    
    esp_err_t err = esp_http_client_perform(client);
    int status = esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);
    
    if (err != ESP_OK || status != 200) {
        ESP_LOGE(TAG, "DoH request failed: %s, status=%d", esp_err_to_name(err), status);
        return -1;
    }
    
    // Parse response
    return parse_dns_response(response, ctx.response_len, ip_out);
}

// ============================================================================
// DNS Lookup Test
// ============================================================================

static void dns_lookup_test(void) {
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "=== DNS Lookup Test ===");
    
    // AliDNS servers
    uint32_t alidns_primary = inet_addr("223.5.5.5");
    uint32_t alidns_backup = inet_addr("223.6.6.6");
    
    uint8_t ip[4];
    
    // Test with UDP - AliDNS
    ESP_LOGI(TAG, "--- UDP DNS (223.5.5.5 AliDNS) ---");
    for (int i = 0; i < NUM_TEST_DOMAINS; i++) {
        if (dns_resolve_udp(test_domains[i], alidns_primary, ip) == 0) {
            ESP_LOGI(TAG, "%s => %d.%d.%d.%d", test_domains[i], ip[0], ip[1], ip[2], ip[3]);
        } else {
            ESP_LOGE(TAG, "%s => failed", test_domains[i]);
        }
    }
    
    // Test with TCP - AliDNS
    ESP_LOGI(TAG, "--- TCP DNS (223.5.5.5 AliDNS) ---");
    for (int i = 0; i < NUM_TEST_DOMAINS; i++) {
        if (dns_resolve_tcp(test_domains[i], alidns_primary, ip) == 0) {
            ESP_LOGI(TAG, "%s => %d.%d.%d.%d", test_domains[i], ip[0], ip[1], ip[2], ip[3]);
        } else {
            ESP_LOGE(TAG, "%s => failed", test_domains[i]);
        }
    }
    
    // Test with HTTPS - AliDNS DoH
    ESP_LOGI(TAG, "--- HTTPS DNS (223.5.5.5 AliDNS DoH) ---");
    for (int i = 0; i < NUM_TEST_DOMAINS; i++) {
        if (dns_resolve_https(test_domains[i], "223.5.5.5", ip) == 0) {
            ESP_LOGI(TAG, "%s => %d.%d.%d.%d", test_domains[i], ip[0], ip[1], ip[2], ip[3]);
        } else {
            ESP_LOGE(TAG, "%s => failed", test_domains[i]);
        }
    }
    
    // Test with backup AliDNS
    ESP_LOGI(TAG, "--- UDP DNS (223.6.6.6 AliDNS Backup) ---");
    if (dns_resolve_udp("example.com", alidns_backup, ip) == 0) {
        ESP_LOGI(TAG, "example.com => %d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
    } else {
        ESP_LOGE(TAG, "example.com => failed");
    }
}

// ============================================================================
// Main
// ============================================================================

void app_main(void)
{
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "  WiFi DNS Lookup - C Version");
    ESP_LOGI(TAG, "  Build Tag: %s", BUILD_TAG);
    ESP_LOGI(TAG, "==========================================");
    
    print_memory_stats();
    
    // Initialize NVS
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);
    
    // Connect to WiFi
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "Initializing WiFi...");
    if (wifi_init_sta() != ESP_OK) {
        ESP_LOGE(TAG, "WiFi connection failed. Halting.");
        while (1) {
            vTaskDelay(pdMS_TO_TICKS(1000));
        }
    }
    
    print_memory_stats();
    
    // Run DNS lookup tests
    dns_lookup_test();
    
    // Keep running
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "=== Test Complete ===");
    
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(10000));
        ESP_LOGI(TAG, "Still running...");
    }
}
