# WiFi module for ESP Zig
# Include this in main/CMakeLists.txt if using WiFi
#
# Provides:
#   WIFI_C_SOURCES - C helper sources
#   WIFI_FORCE_LINK - Force link symbols

# C helper sources
file(GLOB WIFI_C_SOURCES "${CMAKE_CURRENT_LIST_DIR}/*.c")

# Force link symbols (new modular API)
set(WIFI_FORCE_LINK
    wifi_helper_init
    wifi_helper_deinit
    wifi_helper_set_mode
    wifi_helper_set_sta_config
    wifi_helper_set_ap_config
    wifi_helper_start
    wifi_helper_stop
    wifi_helper_connect
    wifi_helper_disconnect
    wifi_helper_get_sta_ip
    wifi_helper_get_rssi
    wifi_helper_get_ap_station_count
    wifi_helper_get_ap_stations
    wifi_helper_legacy_init
    wifi_helper_legacy_connect
    wifi_helper_get_ip
)
