# esp_timer module CMake configuration

set(ESP_TIMER_C_SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/helper.c"
)

set(ESP_TIMER_FORCE_LINK
    esp_timer_create_oneshot
)
