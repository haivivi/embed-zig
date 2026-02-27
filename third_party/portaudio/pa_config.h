/* PortAudio configuration for Bazel build */

#ifndef PA_CONFIG_H
#define PA_CONFIG_H

/* Platform detection */
#ifdef __APPLE__
#define PA_USE_COREAUDIO 1
#elif defined(__linux__)
#define PA_USE_ALSA 1
#endif

/* Disable debug output */
#define PA_DISABLE_DEBUG_OUTPUT 1

#endif /* PA_CONFIG_H */
