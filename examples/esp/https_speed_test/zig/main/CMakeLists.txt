# HTTPS Speed Test - Zig std Version

idf_component_register(
    SRCS "src/stub.c"
    INCLUDE_DIRS "src"
    REQUIRES esp_wifi esp_netif nvs_flash esp_http_client mbedtls
)

esp_zig_build()
