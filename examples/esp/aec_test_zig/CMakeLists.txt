# AEC Test (Zig) - Pure Zig implementation using lib/esp modules
#
# Build: idf.py build
# Flash: idf.py -p PORT flash monitor

cmake_minimum_required(VERSION 3.16)

# Include esp-sr from ADF_PATH
set(EXTRA_COMPONENT_DIRS
    $ENV{ADF_PATH}/components/esp-sr
)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(aec_test_zig)
