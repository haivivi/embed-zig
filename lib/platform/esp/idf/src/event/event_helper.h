/**
 * Event Loop Helper
 *
 * Manages the default ESP-IDF event loop.
 * This is the foundation for all event-driven components (WiFi, Net, etc.)
 */

#ifndef EVENT_HELPER_H
#define EVENT_HELPER_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize the default event loop (idempotent)
 * @return 0 on success, -1 on error
 */
int event_helper_init(void);

/**
 * Deinitialize the default event loop
 */
void event_helper_deinit(void);

/**
 * Check if event loop is initialized
 * @return true if initialized
 */
bool event_helper_is_initialized(void);

#ifdef __cplusplus
}
#endif

#endif // EVENT_HELPER_H
