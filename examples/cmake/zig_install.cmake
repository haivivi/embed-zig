# zig_install.cmake
# Auto-detect host system and find the appropriate Zig installation
#
# This module will:
# 1. Detect host OS and architecture
# 2. Map to Zig target triple
# 3. Find matching Zig installation in .out/ directory
# 4. Set ZIG_INSTALL variable or show build instructions
#
# Usage: include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/zig_install.cmake)

# Get the examples root directory (where cmake/ folder is)
get_filename_component(_ZIG_EXAMPLES_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
get_filename_component(_ZIG_REPO_ROOT "${_ZIG_EXAMPLES_ROOT}/.." ABSOLUTE)

# =============================================================================
# Step 1: Detect host system
# =============================================================================
set(_HOST_OS "${CMAKE_HOST_SYSTEM_NAME}")
set(_HOST_ARCH "${CMAKE_HOST_SYSTEM_PROCESSOR}")

# CMAKE_HOST_SYSTEM_PROCESSOR may be empty in early CMake stages, use uname as fallback
if(_HOST_ARCH STREQUAL "")
    execute_process(
        COMMAND uname -m
        OUTPUT_VARIABLE _HOST_ARCH
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
endif()

message(STATUS "[zig_install] Detecting host: ${_HOST_OS} ${_HOST_ARCH}")

# =============================================================================
# Step 2: Map to Zig target triple
# =============================================================================
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
# Step 3: Find espressif version directory and Zig installation
# =============================================================================

# Find all espressif-* directories and sort to get the latest
file(GLOB _ESPRESSIF_DIRS "${_ZIG_REPO_ROOT}/espressif-*")
list(SORT _ESPRESSIF_DIRS ORDER DESCENDING)

if(NOT _ESPRESSIF_DIRS)
    message(FATAL_ERROR "[zig_install] No espressif-* directory found in ${_ZIG_REPO_ROOT}")
endif()

# Use the latest espressif version by default, or allow override
if(NOT DEFINED ESPRESSIF_VERSION)
    list(GET _ESPRESSIF_DIRS 0 _ESPRESSIF_DIR)
    get_filename_component(ESPRESSIF_VERSION "${_ESPRESSIF_DIR}" NAME)
else()
    set(_ESPRESSIF_DIR "${_ZIG_REPO_ROOT}/${ESPRESSIF_VERSION}")
    if(NOT EXISTS "${_ESPRESSIF_DIR}")
        message(FATAL_ERROR "[zig_install] Specified ESPRESSIF_VERSION '${ESPRESSIF_VERSION}' not found")
    endif()
endif()

message(STATUS "[zig_install] Using espressif version: ${ESPRESSIF_VERSION}")

# Look for matching Zig installation in .out/ directory
set(_ZIG_OUT_DIR "${_ESPRESSIF_DIR}/.out")

if(NOT EXISTS "${_ZIG_OUT_DIR}")
    # .out directory doesn't exist - need to build
    message(FATAL_ERROR 
        "\n"
        "================================================================================\n"
        "[zig_install] Zig installation not found!\n"
        "================================================================================\n"
        "\n"
        "No .out/ directory exists in ${ESPRESSIF_VERSION}\n"
        "\n"
        "Please build Zig for your platform first:\n"
        "\n"
        "    cd ${_ZIG_REPO_ROOT}\n"
        "    ./bootstrap.sh ${ESPRESSIF_VERSION} ${_ZIG_TARGET} baseline\n"
        "\n"
        "================================================================================\n"
    )
endif()

# Find zig-{target}-* directories (mcpu can vary: baseline, native, etc.)
file(GLOB _ZIG_INSTALLS "${_ZIG_OUT_DIR}/zig-${_ZIG_TARGET}-*")

if(NOT _ZIG_INSTALLS)
    # No matching installation found
    # List available installations for reference
    file(GLOB _AVAILABLE_INSTALLS "${_ZIG_OUT_DIR}/zig-*")
    set(_AVAILABLE_LIST "")
    foreach(_inst ${_AVAILABLE_INSTALLS})
        get_filename_component(_inst_name "${_inst}" NAME)
        string(APPEND _AVAILABLE_LIST "    - ${_inst_name}\n")
    endforeach()
    
    if(_AVAILABLE_LIST STREQUAL "")
        set(_AVAILABLE_LIST "    (none)\n")
    endif()
    
    message(FATAL_ERROR 
        "\n"
        "================================================================================\n"
        "[zig_install] No Zig installation found for ${_ZIG_TARGET}!\n"
        "================================================================================\n"
        "\n"
        "Available installations in ${ESPRESSIF_VERSION}/.out/:\n"
        "${_AVAILABLE_LIST}"
        "\n"
        "Please build Zig for your platform:\n"
        "\n"
        "    cd ${_ZIG_REPO_ROOT}\n"
        "    ./bootstrap.sh ${ESPRESSIF_VERSION} ${_ZIG_TARGET} baseline\n"
        "\n"
        "================================================================================\n"
    )
endif()

# Use the first matching installation (usually there's only one per target)
list(GET _ZIG_INSTALLS 0 ZIG_INSTALL)
get_filename_component(_ZIG_INSTALL_NAME "${ZIG_INSTALL}" NAME)

message(STATUS "[zig_install] Found: ${_ZIG_INSTALL_NAME}")
message(STATUS "[zig_install] ZIG_INSTALL = ${ZIG_INSTALL}")

# Clean up internal variables
unset(_HOST_OS)
unset(_HOST_ARCH)
unset(_ZIG_OS)
unset(_ZIG_ABI)
unset(_ZIG_ARCH)
unset(_ZIG_TARGET)
unset(_ZIG_EXAMPLES_ROOT)
unset(_ZIG_REPO_ROOT)
unset(_ESPRESSIF_DIRS)
unset(_ESPRESSIF_DIR)
unset(_ZIG_OUT_DIR)
unset(_ZIG_INSTALLS)
unset(_ZIG_INSTALL_NAME)
unset(_AVAILABLE_INSTALLS)
unset(_AVAILABLE_LIST)
