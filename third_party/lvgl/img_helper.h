/**
 * C helper to create LVGL image descriptors from raw PNG data.
 * Needed because lv_image_header_t has bit-fields that Zig cannot handle.
 *
 * Returns opaque pointers safe to pass to lv_image_set_src().
 */
#ifndef IMG_HELPER_H
#define IMG_HELPER_H

#include <stdint.h>

/**
 * Create a persistent image descriptor from raw PNG data in memory.
 * Returns opaque pointer for lv_image_set_src(). NULL on allocation failure.
 * Caller must NOT free the returned pointer (owned by LVGL heap).
 */
const void * img_png_src(const void *png_data, uint32_t png_size);

#endif
