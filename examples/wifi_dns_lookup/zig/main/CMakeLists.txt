set(REQUIRES
    esp_wifi
    esp_event
    esp_netif
    nvs_flash
    lwip
)

idf_component_register(
    SRCS "src/main.c"
    INCLUDE_DIRS "."
    REQUIRES ${REQUIRES}
)

set(ZIG_INSTALL ../../../../espressif-0.15.x/.out/zig-aarch64-macos-none-baseline)

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
    else(CONFIG_IDF_TARGET_ESP32S3)
        set(TARGET_CPU_MODEL "esp32s3")
    endif()
else()
    message(FATAL_ERROR "Unsupported target ${CONFIG_IDF_TARGET}")
endif()

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(ZIG_BUILD_TYPE "Debug")
else()
    set(ZIG_BUILD_TYPE "ReleaseSafe")
endif()

set(include_dirs $<TARGET_PROPERTY:${COMPONENT_LIB},INCLUDE_DIRECTORIES> ${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES})

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

add_prebuilt_library(zig ${CMAKE_BINARY_DIR}/lib/libmain_zig.a)
add_dependencies(zig zig_build)
target_link_libraries(${COMPONENT_LIB} PRIVATE ${CMAKE_BINARY_DIR}/lib/libmain_zig.a)

# Force link the WiFi helper functions and socket functions
set_property(TARGET ${COMPONENT_LIB} APPEND PROPERTY 
    INTERFACE_LINK_OPTIONS 
    "-Wl,-u,wifi_helper_init"
    "-Wl,-u,wifi_helper_connect"
    "-Wl,-u,wifi_helper_get_state"
    "-Wl,-u,wifi_helper_get_ip"
    "-Wl,-u,wifi_helper_disconnect"
)
