# BLE Controller + VHCI transport helper for ESP Zig
# Include this in main/CMakeLists.txt if using BLE
#
# Provides:
#   BT_C_SOURCES - C helper sources
#   BT_C_INCLUDE_DIRS - Include directories
#   BT_FORCE_LINK - Force link symbols
#
# Usage:
#   include(${_ESP_LIB}/esp/idf/src/bt/bt.cmake)
#   Then add BT_C_SOURCES to your SRCS in idf_component_register()

# C helper source
set(BT_C_SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/bt_helper.c"
)

# Include directories for C headers
set(BT_C_INCLUDE_DIRS "${CMAKE_CURRENT_LIST_DIR}")

# Force link symbols
set(BT_FORCE_LINK
    bt_helper_init
    bt_helper_deinit
    bt_helper_can_send
    bt_helper_send
    bt_helper_recv
    bt_helper_has_data
)

message(STATUS "[bt] C sources: ${BT_C_SOURCES}")
message(STATUS "[bt] Include dirs: ${BT_C_INCLUDE_DIRS}")
