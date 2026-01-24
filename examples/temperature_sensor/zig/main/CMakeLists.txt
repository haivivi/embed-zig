# Temperature Sensor - Zig Version

idf_component_register(
    SRCS "src/main.c"
    INCLUDE_DIRS "."
    REQUIRES driver esp_adc esp_driver_tsens
)

esp_zig_build(
    FORCE_LINK
        temperature_sensor_install
)
