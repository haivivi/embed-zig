# zig_install.cmake
# Auto-detect Zig installation and provide build function
#
# Usage in project root CMakeLists.txt:
#   include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/zig_install.cmake)
#
# Usage in main/CMakeLists.txt:
#   include(${_ESP_PKG}/src/wifi/wifi.cmake)  # Module: sets WIFI_C_SOURCES, WIFI_FORCE_LINK
#   idf_component_register(SRCS "src/stub.c" ${WIFI_C_SOURCES} REQUIRES ...)
#   esp_zig_build(FORCE_LINK ${WIFI_FORCE_LINK} extra_symbols...)

# =============================================================================
# Step 1: Detect host and find Zig installation
# =============================================================================
get_filename_component(_ZIG_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
get_filename_component(_ZIG_REPO_ROOT "${_ZIG_CMAKE_DIR}/../.." ABSOLUTE)

set(_HOST_OS "${CMAKE_HOST_SYSTEM_NAME}")
set(_HOST_ARCH "${CMAKE_HOST_SYSTEM_PROCESSOR}")

if(_HOST_ARCH STREQUAL "")
    execute_process(COMMAND uname -m OUTPUT_VARIABLE _HOST_ARCH OUTPUT_STRIP_TRAILING_WHITESPACE)
endif()

message(STATUS "[zig_install] Detecting host: ${_HOST_OS} ${_HOST_ARCH}")

# Map OS
if(_HOST_OS STREQUAL "Darwin")
    set(_ZIG_OS "macos")
    set(_ZIG_ABI "none")
elseif(_HOST_OS STREQUAL "Linux")
    set(_ZIG_OS "linux")
    set(_ZIG_ABI "gnu")
elseif(_HOST_OS STREQUAL "Windows")
    set(_ZIG_OS "windows")
    set(_ZIG_ABI "gnu")
else()
    message(FATAL_ERROR "[zig_install] Unsupported host OS: ${_HOST_OS}")
endif()

# Map architecture
if(_HOST_ARCH STREQUAL "arm64" OR _HOST_ARCH STREQUAL "aarch64")
    set(_ZIG_ARCH "aarch64")
elseif(_HOST_ARCH STREQUAL "x86_64" OR _HOST_ARCH STREQUAL "AMD64")
    set(_ZIG_ARCH "x86_64")
else()
    message(FATAL_ERROR "[zig_install] Unsupported host architecture: ${_HOST_ARCH}")
endif()

set(_ZIG_TARGET "${_ZIG_ARCH}-${_ZIG_OS}-${_ZIG_ABI}")
message(STATUS "[zig_install] Looking for Zig target: ${_ZIG_TARGET}")

# Find espressif version
file(GLOB _ESPRESSIF_DIRS "${_ZIG_REPO_ROOT}/espressif-*")
list(SORT _ESPRESSIF_DIRS ORDER DESCENDING)

if(NOT _ESPRESSIF_DIRS)
    message(FATAL_ERROR "[zig_install] No espressif-* directory found")
endif()

list(GET _ESPRESSIF_DIRS 0 _ESPRESSIF_DIR)
get_filename_component(ESPRESSIF_VERSION "${_ESPRESSIF_DIR}" NAME)
message(STATUS "[zig_install] Using espressif version: ${ESPRESSIF_VERSION}")

# Find Zig installation
set(_ZIG_OUT_DIR "${_ESPRESSIF_DIR}/.out")
file(GLOB _ZIG_INSTALLS "${_ZIG_OUT_DIR}/zig-${_ZIG_TARGET}-*")

if(NOT _ZIG_INSTALLS)
    message(FATAL_ERROR "[zig_install] No Zig installation found for ${_ZIG_TARGET}")
endif()

list(GET _ZIG_INSTALLS 0 ZIG_INSTALL)
set(ZIG_INSTALL "${ZIG_INSTALL}" CACHE PATH "Path to Zig installation" FORCE)
message(STATUS "[zig_install] Found: ${ZIG_INSTALL}")

# =============================================================================
# Step 2: Zig build function - call after idf_component_register()
# =============================================================================
function(esp_zig_build)
    cmake_parse_arguments(ARG "" "" "FORCE_LINK" ${ARGN})
    
    # Detect target architecture
    if(CONFIG_IDF_TARGET_ARCH_RISCV)
        set(ZIG_TARGET "riscv32-freestanding-none")
        if(CONFIG_IDF_TARGET_ESP32C6 OR CONFIG_IDF_TARGET_ESP32C5 OR CONFIG_IDF_TARGET_ESP32H2)
            set(TARGET_CPU_MODEL "generic_rv32+m+a+c+zicsr+zifencei")
        elseif(CONFIG_IDF_TARGET_ESP32P4)
            string(REGEX REPLACE "-none" "-eabihf" ZIG_TARGET ${ZIG_TARGET})
            set(TARGET_CPU_MODEL "esp32p4-zca-zcb-zcmt-zcmp")
        else()
            set(TARGET_CPU_MODEL "generic_rv32+m+c+zicsr+zifencei")
        endif()
    elseif(CONFIG_IDF_TARGET_ARCH_XTENSA)
        set(ZIG_TARGET "xtensa-freestanding-none")
        if(CONFIG_IDF_TARGET_ESP32)
            set(TARGET_CPU_MODEL "esp32")
        elseif(CONFIG_IDF_TARGET_ESP32S2)
            set(TARGET_CPU_MODEL "esp32s2")
        else()
            set(TARGET_CPU_MODEL "esp32s3")
        endif()
    else()
        message(FATAL_ERROR "Unsupported target ${CONFIG_IDF_TARGET}")
    endif()
    
    # Build type
    if(CMAKE_BUILD_TYPE STREQUAL "Debug")
        set(ZIG_BUILD_TYPE "Debug")
    else()
        set(ZIG_BUILD_TYPE "ReleaseSafe")
    endif()
    
    # Include directories
    set(include_dirs $<TARGET_PROPERTY:${COMPONENT_LIB},INCLUDE_DIRECTORIES> ${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES})
    
    # Zig build target
    add_custom_target(zig_build
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        COMMAND ${CMAKE_COMMAND} -E env "INCLUDE_DIRS=${include_dirs}"
        ${ZIG_INSTALL}/zig build
            --build-file build.zig
            -Doptimize=${ZIG_BUILD_TYPE}
            -Dtarget=${ZIG_TARGET}
            -Dcpu=${TARGET_CPU_MODEL}
            -freference-trace
            --prominent-compile-errors
            --cache-dir ${CMAKE_BINARY_DIR}/../.zig-cache
            --prefix ${CMAKE_BINARY_DIR}
        BYPRODUCTS ${CMAKE_BINARY_DIR}/lib/libmain_zig.a
        VERBATIM
    )
    
    # Link Zig library
    add_prebuilt_library(zig ${CMAKE_BINARY_DIR}/lib/libmain_zig.a)
    add_dependencies(zig zig_build)
    target_link_libraries(${COMPONENT_LIB} PRIVATE ${CMAKE_BINARY_DIR}/lib/libmain_zig.a)
    
    # Force link symbols
    foreach(sym ${ARG_FORCE_LINK})
        set_property(TARGET ${COMPONENT_LIB} APPEND PROPERTY 
            INTERFACE_LINK_OPTIONS "-Wl,-u,${sym}")
    endforeach()
endfunction()

# Cleanup
unset(_ZIG_CMAKE_DIR)
unset(_ZIG_REPO_ROOT)
unset(_HOST_OS)
unset(_HOST_ARCH)
unset(_ZIG_OS)
unset(_ZIG_ABI)
unset(_ZIG_ARCH)
unset(_ZIG_TARGET)
unset(_ESPRESSIF_DIRS)
unset(_ESPRESSIF_DIR)
unset(_ZIG_OUT_DIR)
unset(_ZIG_INSTALLS)
