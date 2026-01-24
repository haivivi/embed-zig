# Memory Attr Test - Zig Version

idf_component_register(
    SRCS "src/main.c"
    INCLUDE_DIRS "."
    REQUIRES driver
)

esp_zig_build()
