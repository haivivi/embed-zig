# Network Interface C helpers for ESP Zig
# Include this in main/CMakeLists.txt if using net trait
#
# Provides:
#   NET_C_SOURCES - C helper sources for esp_netif integration
#   NET_C_INCLUDE_DIRS - Include directories for C helpers
#   NET_FORCE_LINK - Force link symbols
#
# These helpers wrap esp_netif APIs that use opaque structures,
# exposing simple byte-array interfaces for Zig.
#
# Usage:
#   include(${_ESP_LIB}/esp/src/idf/net/net.cmake)
#   Then add NET_C_SOURCES to your SRCS in idf_component_register()

# C helper sources
set(NET_C_SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/netif_helper.c"
    "${CMAKE_CURRENT_LIST_DIR}/socket_helper.c"
)

# Include directories for C headers
set(NET_C_INCLUDE_DIRS "${CMAKE_CURRENT_LIST_DIR}")

# Force link symbols
set(NET_FORCE_LINK
    # Socket helpers
    socket_set_recv_timeout
    socket_set_send_timeout
    # Info queries
    netif_helper_count
    netif_helper_get_name
    netif_helper_get_info
    netif_helper_get_default
    netif_helper_get_dns
    # Configuration
    netif_helper_set_default
    netif_helper_set_dns
    netif_helper_up
    netif_helper_down
    # Static IP
    netif_helper_set_static_ip
    netif_helper_enable_dhcp_client
    # DHCP Server
    netif_helper_configure_dhcps
    netif_helper_set_dhcps_dns
    netif_helper_start_dhcps
    netif_helper_stop_dhcps
    # Events
    netif_helper_event_init
    netif_helper_poll_event
)

# Debug: print the sources
message(STATUS "[net] C sources: ${NET_C_SOURCES}")
message(STATUS "[net] Include dirs: ${NET_C_INCLUDE_DIRS}")

# Function to add include directories to component target
# Call this AFTER idf_component_register()
#
# Usage:
#   idf_component_register(...)
#   net_setup_includes()
function(net_setup_includes)
    if(TARGET ${COMPONENT_LIB})
        # Use PUBLIC so these directories are visible to Zig via INCLUDE_DIRECTORIES property
        target_include_directories(${COMPONENT_LIB} PUBLIC ${NET_C_INCLUDE_DIRS})
    endif()
endfunction()
