# ESP-IDF Entry Point CMake module
# Provides C entry point for pure-Zig ESP-IDF applications
#
# Usage:
#   include(${_ESP_LIB}/entry/entry.cmake)
#   # Then add ${ENTRY_C_SOURCES} to idf_component_register SRCS

get_filename_component(_ENTRY_DIR "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)

set(ENTRY_C_SOURCES
    "${_ENTRY_DIR}/entry.c"
)
