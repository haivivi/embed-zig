idf_component_register(
    SRCS "aec_test.c"
    INCLUDE_DIRS "."
    REQUIRES driver esp_timer freertos
    PRIV_REQUIRES esp-sr heap esp_codec_dev
)
