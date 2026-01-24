cmake_minimum_required(VERSION 3.16)

# Auto-detect and set ZIG_INSTALL based on host system
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/zig_install.cmake)

set(EXTRA_COMPONENT_DIRS "main")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(wifi_dns_lookup_zig)
