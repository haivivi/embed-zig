# KCP C library for ESP-IDF builds
get_filename_component(_KCP_DIR "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
set(KCP_C_SOURCES "${_KCP_DIR}/ikcp.c")
macro(kcp_setup_includes)
    target_include_directories(${COMPONENT_LIB} PRIVATE "${_KCP_DIR}")
endmacro()
