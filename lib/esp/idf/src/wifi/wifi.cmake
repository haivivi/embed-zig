# WiFi module for ESP Zig
# Include this in main/CMakeLists.txt if using WiFi
#
# Provides:
#   WIFI_C_SOURCES - C helper sources
#   WIFI_FORCE_LINK - Force link symbols

# C helper sources
file(GLOB WIFI_C_SOURCES "${CMAKE_CURRENT_LIST_DIR}/*.c")

# Force link symbols
set(WIFI_FORCE_LINK
    wifi_helper_nvs_init
    wifi_helper_init
    wifi_helper_connect
    wifi_helper_get_ip
    wifi_helper_disconnect
)
