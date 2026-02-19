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

#endif
