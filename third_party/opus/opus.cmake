# Opus library CMake configuration for ESP-IDF builds
# Builds opus as a separate static library (not part of main component)
# to ensure correct link ordering with libmain_zig.a
#
# OPUS_ROOT: path to opus source tree (from env var, set by build script)

if(NOT DEFINED OPUS_ROOT OR OPUS_ROOT STREQUAL "")
    set(OPUS_ROOT $ENV{OPUS_ROOT})
endif()

# Collect opus source files (safe in script mode — just sets variables)
if(NOT OPUS_ROOT STREQUAL "")
    file(GLOB _OPUS_CORE_SRCS
        "${OPUS_ROOT}/src/*.c"
        "${OPUS_ROOT}/celt/*.c"
        "${OPUS_ROOT}/silk/*.c"
    )
    file(GLOB _OPUS_FIXED_SRCS
        "${OPUS_ROOT}/silk/fixed/*.c"
    )

    # Remove demo/test/platform-specific files
    list(FILTER _OPUS_CORE_SRCS EXCLUDE REGEX "opus_demo\\.c$")
    list(FILTER _OPUS_CORE_SRCS EXCLUDE REGEX "opus_compare\\.c$")
    list(FILTER _OPUS_CORE_SRCS EXCLUDE REGEX "repacketizer_demo\\.c$")
    list(FILTER _OPUS_CORE_SRCS EXCLUDE REGEX "opus_custom_demo\\.c$")
    list(FILTER _OPUS_CORE_SRCS EXCLUDE REGEX "/arm/")
    list(FILTER _OPUS_CORE_SRCS EXCLUDE REGEX "/x86/")
    list(FILTER _OPUS_FIXED_SRCS EXCLUDE REGEX "/arm/")
    list(FILTER _OPUS_FIXED_SRCS EXCLUDE REGEX "/x86/")

    set(_OPUS_ALL_SRCS ${_OPUS_CORE_SRCS} ${_OPUS_FIXED_SRCS})
endif()

# Called after idf_component_register (build mode only)
# Builds opus as separate library and links it to the component
macro(opus_setup_includes)
    if(NOT OPUS_ROOT STREQUAL "")
        add_library(opus_lib STATIC ${_OPUS_ALL_SRCS})
        target_include_directories(opus_lib PRIVATE
            "${OPUS_ROOT}/include"
            "${OPUS_ROOT}/src"
            "${OPUS_ROOT}/celt"
            "${OPUS_ROOT}/silk"
            "${OPUS_ROOT}/silk/fixed"
        )
        target_compile_definitions(opus_lib PRIVATE
            OPUS_BUILD HAVE_LRINTF VAR_ARRAYS FIXED_POINT
        )
        target_compile_options(opus_lib PRIVATE -w)

        # Include opus.h for zig's @cImport
        target_include_directories(${COMPONENT_LIB} PRIVATE "${OPUS_ROOT}/include")
        # Link opus AFTER libmain_zig.a to resolve opus symbols
        target_link_libraries(${COMPONENT_LIB} PRIVATE opus_lib)
    endif()
endmacro()
