/**
 * bk_zig_heap_helper.c — Heap allocation for Zig (PSRAM + SRAM)
 */

#include <os/mem.h>
#include <string.h>

void *bk_zig_psram_malloc(unsigned int size) {
    return psram_malloc(size);
}

void *bk_zig_psram_zalloc(unsigned int size) {
    return psram_zalloc(size);
}

void *bk_zig_sram_malloc(unsigned int size) {
    return os_malloc(size);
}

void bk_zig_free(void *ptr) {
    os_free(ptr);
}

unsigned int bk_zig_psram_get_free(void) {
    /* Approximate: total PSRAM - used */
    return 0; /* TODO: implement if Armino provides API */
}
