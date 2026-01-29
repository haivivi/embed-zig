# zig_install.cmake
# Auto-detect Zig installation with Xtensa support
#
# Search order:
#   1. ZIG_INSTALL environment variable (direct path to zig installation)
#   2. Bazel external repository (bazel-<workspace>/external/+zig_toolchain+zig_toolchain)
#   3. Default location (~/.local/embed-zig/bootstrap/esp/...)
#
# Usage in project root CMakeLists.txt:
#   include(${CMAKE_CURRENT_SOURCE_DIR}/../cmake/zig_install.cmake)
#
# Usage in main/CMakeLists.txt:
#   esp_zig_build(FORCE_LINK symbol1 symbol2 ...)

# =============================================================================
# Step 1: Detect host platform
# =============================================================================
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

# =============================================================================
# Step 2: Find Zig installation
# =============================================================================
set(ZIG_INSTALL "" CACHE PATH "Path to Zig installation with Xtensa support")

# Method 1: Environment variable ZIG_INSTALL
if(DEFINED ENV{ZIG_INSTALL} AND EXISTS "$ENV{ZIG_INSTALL}/zig")
    set(ZIG_INSTALL "$ENV{ZIG_INSTALL}" CACHE PATH "Path to Zig installation" FORCE)
    message(STATUS "[zig_install] Found via ZIG_INSTALL env: ${ZIG_INSTALL}")
endif()

# Method 2: Bazel external repository (bzlmod format)
if(NOT ZIG_INSTALL OR NOT EXISTS "${ZIG_INSTALL}/zig")
    get_filename_component(_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
    get_filename_component(_PROJECT_ROOT "${_CMAKE_DIR}/.." ABSOLUTE)
    
    file(GLOB _BAZEL_DIRS "${_PROJECT_ROOT}/bazel-*")
    foreach(_BAZEL_DIR ${_BAZEL_DIRS})
        # Try bzlmod format: +zig_toolchain+zig_toolchain
        set(_BAZEL_ZIG "${_BAZEL_DIR}/external/+zig_toolchain+zig_toolchain")
        if(EXISTS "${_BAZEL_ZIG}/zig")
            set(ZIG_INSTALL "${_BAZEL_ZIG}" CACHE PATH "Path to Zig installation" FORCE)
            message(STATUS "[zig_install] Found via Bazel (bzlmod): ${ZIG_INSTALL}")
            break()
        endif()
        # Fallback to legacy format
        set(_BAZEL_ZIG "${_BAZEL_DIR}/external/zig_toolchain")
        if(EXISTS "${_BAZEL_ZIG}/zig")
            set(ZIG_INSTALL "${_BAZEL_ZIG}" CACHE PATH "Path to Zig installation" FORCE)
            message(STATUS "[zig_install] Found via Bazel (legacy): ${ZIG_INSTALL}")
            break()
        endif()
    endforeach()
endif()

# Method 3: Default embed-zig location
if(NOT ZIG_INSTALL OR NOT EXISTS "${ZIG_INSTALL}/zig")
    if(DEFINED ENV{EMBED_ZIG_ROOT})
        set(_EMBED_ZIG_ROOT "$ENV{EMBED_ZIG_ROOT}")
    else()
        set(_EMBED_ZIG_ROOT "$ENV{HOME}/.local/embed-zig")
    endif()
    
    file(GLOB _ESPRESSIF_DIRS "${_EMBED_ZIG_ROOT}/bootstrap/esp/*")
    if(_ESPRESSIF_DIRS)
        list(SORT _ESPRESSIF_DIRS ORDER DESCENDING)
        list(GET _ESPRESSIF_DIRS 0 _ESPRESSIF_DIR)
        
        set(_ZIG_OUT_DIR "${_ESPRESSIF_DIR}/.out")
        file(GLOB _ZIG_INSTALLS "${_ZIG_OUT_DIR}/zig-${_ZIG_TARGET}-*")
        
        if(_ZIG_INSTALLS)
            list(GET _ZIG_INSTALLS 0 ZIG_INSTALL)
            set(ZIG_INSTALL "${ZIG_INSTALL}" CACHE PATH "Path to Zig installation" FORCE)
            message(STATUS "[zig_install] Found via embed-zig: ${ZIG_INSTALL}")
        endif()
    endif()
endif()

# Final check
if(NOT ZIG_INSTALL OR NOT EXISTS "${ZIG_INSTALL}/zig")
    message(FATAL_ERROR "[zig_install] Could not find Zig with Xtensa support!

Please do ONE of the following:

1. Run 'bazel build @zig_toolchain//:zig_files' first to download Zig

2. Set ZIG_INSTALL environment variable:
   export ZIG_INSTALL=/path/to/zig-${_ZIG_TARGET}-baseline

3. Download from: https://github.com/haivivi/embed-zig/releases
   and extract to ~/.local/embed-zig/bootstrap/esp/espressif-0.15.x/.out/
")
endif()

message(STATUS "[zig_install] Using Zig: ${ZIG_INSTALL}")

# =============================================================================
# Step 3: Zig build function - call after idf_component_register()
# =============================================================================
function(esp_zig_build)
    cmake_parse_arguments(ARG "" "" "FORCE_LINK" ${ARGN})
    
    # Get board from environment or CMake variable
    if(DEFINED ENV{ZIG_BOARD})
        set(ZIG_BOARD "$ENV{ZIG_BOARD}")
    elseif(NOT DEFINED ZIG_BOARD)
        set(ZIG_BOARD "esp32s3_devkit")
    endif()
    message(STATUS "[esp_zig_build] Board: ${ZIG_BOARD}")
    
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
            ${ZIG_OPTIONS}
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

# Cleanup temporary variables
unset(_HOST_OS)
unset(_HOST_ARCH)
unset(_ZIG_OS)
unset(_ZIG_ABI)
unset(_ZIG_ARCH)
unset(_ZIG_TARGET)
unset(_CMAKE_DIR)
unset(_PROJECT_ROOT)
unset(_BAZEL_DIRS)
unset(_BAZEL_DIR)
unset(_BAZEL_ZIG)
unset(_EMBED_ZIG_ROOT)
unset(_ESPRESSIF_DIRS)
unset(_ESPRESSIF_DIR)
unset(_ZIG_OUT_DIR)
unset(_ZIG_INSTALLS)
