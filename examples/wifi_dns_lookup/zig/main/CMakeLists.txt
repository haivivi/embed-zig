# WiFi DNS Lookup - Zig Version

# ESP package path
set(_ESP_PKG ${CMAKE_CURRENT_LIST_DIR}/../../../../esp)

# Include WiFi module
include(${_ESP_PKG}/src/wifi/wifi.cmake)

# IDF component
idf_component_register(
    SRCS "src/stub.c" ${WIFI_C_SOURCES}
    INCLUDE_DIRS "."
    REQUIRES esp_wifi esp_event esp_netif nvs_flash lwip
)

# Build Zig
esp_zig_build(FORCE_LINK ${WIFI_FORCE_LINK})
