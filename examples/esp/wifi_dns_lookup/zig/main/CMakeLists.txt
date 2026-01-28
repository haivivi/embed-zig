# WiFi DNS Lookup - Zig Version

# ESP package path: use ESP_LIB_PATH env var (Bazel) or relative path (local dev)
if(DEFINED ENV{ESP_LIB_PATH})
    set(_ESP_LIB $ENV{ESP_LIB_PATH})
else()
    set(_ESP_LIB ${CMAKE_CURRENT_LIST_DIR}/../../../../../lib)
endif()

# Include WiFi module
include(${_ESP_LIB}/esp/src/wifi/wifi.cmake)

# IDF component
idf_component_register(
    SRCS "src/stub.c" ${WIFI_C_SOURCES}
    INCLUDE_DIRS "."
    REQUIRES esp_wifi esp_event esp_netif nvs_flash lwip esp_http_client
)

# Force link esp_http_client symbols for DoH
set(HTTP_FORCE_LINK
    esp_http_client_init
    esp_http_client_cleanup
)

# Build Zig
esp_zig_build(FORCE_LINK ${WIFI_FORCE_LINK} ${HTTP_FORCE_LINK})
