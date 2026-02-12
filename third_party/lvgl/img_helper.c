#define LV_CONF_INCLUDE_SIMPLE
#include "lvgl.h"
#include "img_helper.h"

const void * img_png_src(const void *png_data, uint32_t png_size) {
    if (png_data == NULL || png_size < 8) return NULL;

    /* Verify PNG signature */
    const uint8_t *p = (const uint8_t *)png_data;
    if (p[0] != 0x89 || p[1] != 'P' || p[2] != 'N' || p[3] != 'G') {
        LV_LOG_WARN("img_png_src: not a PNG (magic: %02x %02x %02x %02x)", p[0], p[1], p[2], p[3]);
        return NULL;
    }

    /* Read dimensions from PNG header (bytes 16-23, big-endian) */
    uint32_t w = 0, h = 0;
    if (png_size >= 24) {
        w = (p[16] << 24) | (p[17] << 16) | (p[18] << 8) | p[19];
        h = (p[20] << 24) | (p[21] << 16) | (p[22] << 8) | p[23];
    }

    lv_image_dsc_t *dsc = lv_malloc(sizeof(lv_image_dsc_t));
    if (dsc == NULL) return NULL;
    lv_memset(dsc, 0, sizeof(*dsc));

    dsc->header.magic = LV_IMAGE_HEADER_MAGIC;
    dsc->header.cf = LV_COLOR_FORMAT_ARGB8888;
    dsc->header.w = w;
    dsc->header.h = h;
    dsc->data = png_data;
    dsc->data_size = png_size;

    LV_LOG_INFO("img_png_src: %dx%d, %u bytes", (int)w, (int)h, (unsigned)png_size);
    return dsc;
}
