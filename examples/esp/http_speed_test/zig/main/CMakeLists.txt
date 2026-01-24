# HTTP Speed Test - Zig esp_http_client version

# ESP package path (relative to this file)
set(_ESP_PKG ${CMAKE_CURRENT_LIST_DIR}/../../../../../lib/esp)

# Include modules (sets variables: WIFI_C_SOURCES, WIFI_FORCE_LINK)
include(${_ESP_PKG}/src/wifi/wifi.cmake)

# IDF component
idf_component_register(
    SRCS "src/stub.c" ${WIFI_C_SOURCES}
    INCLUDE_DIRS "."
    REQUIRES esp_wifi esp_event esp_netif nvs_flash esp_http_client esp_timer lwip
)

# Build Zig
esp_zig_build(
    FORCE_LINK
        ${WIFI_FORCE_LINK}
        esp_http_client_init
        esp_http_client_perform
        esp_http_client_cleanup
        esp_http_client_get_status_code
        esp_http_client_get_content_length
)
