# The following five lines of boilerplate have to be in your project's
# CMakeLists in this exact order for cmake to work correctly
cmake_minimum_required(VERSION 3.16)

# Auto-detect and set ZIG_INSTALL based on host system
include(${CMAKE_CURRENT_SOURCE_DIR}/../../../../cmake/zig_install.cmake)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(led_strip_flash_zig)
