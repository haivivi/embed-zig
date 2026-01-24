cmake_minimum_required(VERSION 3.16)

# Auto-detect and set ZIG_INSTALL based on host system
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/zig_install.cmake)

# Get project name from directory
get_filename_component(CURRENT_DIR ${CMAKE_CURRENT_LIST_FILE} DIRECTORY)
get_filename_component(PROJECT_NAME ${CURRENT_DIR} NAME)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(${PROJECT_NAME})
