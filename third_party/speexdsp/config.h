/* config.h — SpeexDSP build config for zig-cc cross-compilation.
 *
 * Replaces autoconf-generated config.h. Minimal settings for
 * freestanding environments (ESP32, BK7258, WASM).
 */
#ifndef SPEEXDSP_CONFIG_H
#define SPEEXDSP_CONFIG_H

#define HAVE_STDINT_H 1

/* Use smallft (built-in FFT) instead of external FFTW */
#define USE_SMALLFT 1

/* Export symbols */
#define EXPORT

/* Disable alloca — use malloc/calloc instead */
/* #undef VAR_ARRAYS */
/* #undef USE_ALLOCA */

/* Override memory allocation — provided by Zig allocator via @export.
 * This suppresses the default static inline speex_alloc/realloc/free
 * in os_support.h, making them external symbols resolved at link time. */
#define OVERRIDE_SPEEX_ALLOC
#define OVERRIDE_SPEEX_REALLOC
#define OVERRIDE_SPEEX_FREE

/* Declare the override functions (defined in speexdsp.zig) */
extern void *speex_alloc(int size);
extern void *speex_realloc(void *ptr, int size);
extern void speex_free(void *ptr);

#endif
