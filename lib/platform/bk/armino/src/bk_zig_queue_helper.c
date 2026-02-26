/**
 * bk_zig_queue_helper.c — C bridge for Zig Channel <-> FreeRTOS Queue
 *
 * Provides simple C wrappers around FreeRTOS xQueue API that Zig can call.
 */

#include <FreeRTOS.h>
#include <queue.h>

/* Queue handle type - opaque pointer in Zig */
typedef void* bk_queue_handle_t;

/* Create a queue */
bk_queue_handle_t bk_zig_queue_create(unsigned int item_count, unsigned int item_size) {
    return (bk_queue_handle_t)xQueueCreate(item_count, item_size);
}

/* Delete a queue */
void bk_zig_queue_delete(bk_queue_handle_t queue) {
    vQueueDelete((QueueHandle_t)queue);
}

/* Send to queue (blocking with timeout in ms) */
int bk_zig_queue_send(bk_queue_handle_t queue, const void *item, unsigned int timeout_ms) {
    TickType_t ticks = (timeout_ms == 0xFFFFFFFF) ? portMAX_DELAY : (timeout_ms / portTICK_PERIOD_MS);
    return xQueueSend((QueueHandle_t)queue, item, ticks) == pdTRUE ? 0 : -1;
}

/* Receive from queue (blocking with timeout in ms) */
int bk_zig_queue_receive(bk_queue_handle_t queue, void *item, unsigned int timeout_ms) {
    TickType_t ticks = (timeout_ms == 0xFFFFFFFF) ? portMAX_DELAY : (timeout_ms / portTICK_PERIOD_MS);
    return xQueueReceive((QueueHandle_t)queue, item, ticks) == pdTRUE ? 0 : -1;
}

/* Get number of messages waiting in queue */
unsigned int bk_zig_queue_messages_waiting(bk_queue_handle_t queue) {
    return uxQueueMessagesWaiting((QueueHandle_t)queue);
}

/* Create a queue set */
bk_queue_handle_t bk_zig_queue_set_create(unsigned int event_count) {
    return (bk_queue_handle_t)xQueueCreateSet(event_count);
}

/* Delete a queue set */
void bk_zig_queue_set_delete(bk_queue_handle_t queue_set) {
    vQueueDelete((QueueHandle_t)queue_set);
}

/* Add queue to set */
int bk_zig_queue_add_to_set(bk_queue_handle_t queue, bk_queue_handle_t queue_set) {
    return xQueueAddToSet((QueueHandle_t)queue, (QueueSetHandle_t)queue_set) == pdPASS ? 0 : -1;
}

/* Select from queue set (blocking with timeout in ms) */
bk_queue_handle_t bk_zig_queue_select_from_set(bk_queue_handle_t queue_set, unsigned int timeout_ms) {
    TickType_t ticks = (timeout_ms == 0xFFFFFFFF) ? portMAX_DELAY : (timeout_ms / portTICK_PERIOD_MS);
    return (bk_queue_handle_t)xQueueSelectFromSet((QueueSetHandle_t)queue_set, ticks);
}
