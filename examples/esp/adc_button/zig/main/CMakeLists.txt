# ADC Button - Zig Version

idf_component_register(
    SRCS "src/main.c"
    INCLUDE_DIRS "."
    REQUIRES driver esp_adc
)

esp_zig_build(
    FORCE_LINK
        adc_oneshot_new_unit
        adc_oneshot_config_channel
        adc_oneshot_read
        adc_oneshot_del_unit
)
