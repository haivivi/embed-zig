/**
 * bk_zig_heap_helper.c — Heap allocation for Zig (PSRAM + SRAM + aligned)
 *
 * BK7258 memory regions:
 *   SRAM:  ~640KB internal, fast, for small/critical allocations
 *   PSRAM: 8/16MB external, large, for buffers/BLE/TLS state
 */

#include <os/mem.h>
#include <os/os.h>
#include <string.h>
#include <stdlib.h>

/* ======== Basic allocation ======== */

void *bk_zig_psram_malloc(unsigned int size) {
    return psram_malloc(size);
}

void *bk_zig_sram_malloc(unsigned int size) {
    return os_malloc(size);
}

void bk_zig_free(void *ptr) {
    if (ptr) os_free(ptr);
}

/* ======== Aligned allocation (over-allocate + offset) ======== */

void *bk_zig_psram_aligned_alloc(unsigned int alignment, unsigned int size) {
    if (alignment <= 4) return psram_malloc(size);
    /* Over-allocate: size + alignment + sizeof(void*) for storing original ptr */
    unsigned int total = size + alignment + sizeof(void*);
    void *raw = psram_malloc(total);
    if (!raw) return NULL;
    /* Align: skip sizeof(void*) then round up to alignment */
    uintptr_t addr = (uintptr_t)raw + sizeof(void*);
    addr = (addr + alignment - 1) & ~(uintptr_t)(alignment - 1);
    /* Store original pointer just before aligned address */
    ((void **)addr)[-1] = raw;
    return (void *)addr;
}

void *bk_zig_sram_aligned_alloc(unsigned int alignment, unsigned int size) {
    if (alignment <= 4) return os_malloc(size);
    unsigned int total = size + alignment + sizeof(void*);
    void *raw = os_malloc(total);
    if (!raw) return NULL;
    uintptr_t addr = (uintptr_t)raw + sizeof(void*);
    addr = (addr + alignment - 1) & ~(uintptr_t)(alignment - 1);
    ((void **)addr)[-1] = raw;
    return (void *)addr;
}

void bk_zig_aligned_free(void *ptr) {
    if (!ptr) return;
    /* Retrieve original pointer stored before aligned address */
    void *raw = ((void **)ptr)[-1];
    os_free(raw);
}

/* ======== Memory statistics ======== */

/* SRAM (internal) stats */
unsigned int bk_zig_sram_get_total(void) {
    return rtos_get_total_heap_size();
}

unsigned int bk_zig_sram_get_free(void) {
    return rtos_get_free_heap_size();
}

unsigned int bk_zig_sram_get_min_free(void) {
    return rtos_get_minimum_free_heap_size();
}

/* PSRAM (external) stats */
unsigned int bk_zig_psram_get_total(void) {
    return rtos_get_psram_total_heap_size();
}

unsigned int bk_zig_psram_get_free(void) {
    return rtos_get_psram_free_heap_size();
}

unsigned int bk_zig_psram_get_min_free(void) {
    return rtos_get_psram_minimum_free_heap_size();
}

/* ======== Stack statistics ======== */

#include <FreeRTOS.h>
#include <task.h>

unsigned int bk_zig_stack_high_water(void) {
    return uxTaskGetStackHighWaterMark(xTaskGetCurrentTaskHandle());
}
