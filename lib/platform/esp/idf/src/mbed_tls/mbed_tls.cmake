# mbedTLS C helpers for ESP Zig
# Include this in main/CMakeLists.txt if using mbedTLS crypto
#
# Provides:
#   MBED_TLS_C_SOURCES - C helper sources for mbedTLS integration
#   MBED_TLS_C_INCLUDE_DIRS - Include directories for C helpers
#
# These helpers wrap mbedTLS APIs that use opaque structures,
# exposing simple byte-array interfaces for Zig.
#
# Usage:
#   include(${_ESP_LIB}/esp/src/idf/mbed_tls/mbed_tls.cmake)
#   Then add MBED_TLS_C_SOURCES to your SRCS in idf_component_register()

# C helper sources (X25519, P256, P384, AES-GCM, HKDF, RSA, Cert wrappers)
# Use explicit paths instead of GLOB for reliability
set(MBED_TLS_C_SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/x25519_helper.c"
    "${CMAKE_CURRENT_LIST_DIR}/p256_helper.c"
    "${CMAKE_CURRENT_LIST_DIR}/p384_helper.c"
    "${CMAKE_CURRENT_LIST_DIR}/aes_gcm_helper.c"
    "${CMAKE_CURRENT_LIST_DIR}/hkdf_helper.c"
    "${CMAKE_CURRENT_LIST_DIR}/rsa_helper.c"
    "${CMAKE_CURRENT_LIST_DIR}/cert_helper.c"
)

# Include Everest Curve25519 sources directly for X25519 support
# We can't link against libeverest.a due to symbol ordering issues in static linking
# The legacy version uses software 128-bit integers (no __int128 on ESP32/Xtensa)
set(EVEREST_DIR "$ENV{IDF_PATH}/components/mbedtls/mbedtls/3rdparty/everest")
list(APPEND MBED_TLS_C_SOURCES
    "${EVEREST_DIR}/library/kremlib/FStar_UInt128_extracted.c"
    "${EVEREST_DIR}/library/legacy/Hacl_Curve25519.c"
    "${EVEREST_DIR}/library/kremlib/FStar_UInt64_FStar_UInt32_FStar_UInt16_FStar_UInt8.c"
)

# Include directories for C headers
set(MBED_TLS_C_INCLUDE_DIRS "${CMAKE_CURRENT_LIST_DIR}")

# Everest include paths for HACL Curve25519
# The Everest library uses PRIVATE includes, so we need to add them explicitly
# for our x25519_helper.c and the Everest source files to compile.
#
# Include paths needed:
#   1. .../everest/include - for <everest/Hacl_Curve25519.h>
#   2. .../everest/include/everest - for "kremlib.h" and "kremlin/internal/*"
#   3. .../everest/include/everest/kremlib - for FStar types
list(APPEND MBED_TLS_C_INCLUDE_DIRS
    "$ENV{IDF_PATH}/components/mbedtls/mbedtls/3rdparty/everest/include"
    "$ENV{IDF_PATH}/components/mbedtls/mbedtls/3rdparty/everest/include/everest"
    "$ENV{IDF_PATH}/components/mbedtls/mbedtls/3rdparty/everest/include/everest/kremlib"
)

# Debug: print the sources
message(STATUS "[mbed_tls] C sources: ${MBED_TLS_C_SOURCES}")
message(STATUS "[mbed_tls] Include dirs: ${MBED_TLS_C_INCLUDE_DIRS}")

# Function to add Everest include directories and compile definitions to component target
# Call this AFTER idf_component_register()
#
# Usage:
#   idf_component_register(...)
#   mbed_tls_setup_includes()
function(mbed_tls_setup_includes)
    if(TARGET ${COMPONENT_LIB})
        # Use PUBLIC so these directories are visible to Zig via INCLUDE_DIRECTORIES property
        target_include_directories(${COMPONENT_LIB} PUBLIC ${MBED_TLS_C_INCLUDE_DIRS})
        # Define KRML_VERIFIED_UINT128 to use software 128-bit integers
        # ESP32 (Xtensa) doesn't have __int128 support
        target_compile_definitions(${COMPONENT_LIB} PRIVATE KRML_VERIFIED_UINT128)
    endif()
endfunction()

# Also add MBED_TLS_C_INCLUDE_DIRS to a global list that Bazel can use
# This is used by the Zig build to find C headers for @cImport
set(MBED_TLS_INCLUDE_DIRS "${MBED_TLS_C_INCLUDE_DIRS}" PARENT_SCOPE)
