//! FreeRTOS bindings

const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
});

// Task functions
pub const vTaskDelay = c.vTaskDelay;
pub const xTaskCreate = c.xTaskCreate;
pub const vTaskDelete = c.vTaskDelete;

// Constants
pub const portTICK_PERIOD_MS = c.portTICK_PERIOD_MS;
pub const portMAX_DELAY = c.portMAX_DELAY;

// Types
pub const TaskHandle_t = c.TaskHandle_t;
pub const BaseType_t = c.BaseType_t;
pub const TickType_t = c.TickType_t;

/// Delay for specified milliseconds
pub fn delayMs(ms: u32) void {
    vTaskDelay(ms / portTICK_PERIOD_MS);
}
