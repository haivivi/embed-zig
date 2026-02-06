/**
 * Socket Helper
 *
 * C helper functions for socket operations that have type compatibility issues
 * between Zig @cImport and LWIP.
 *
 * Specifically, struct timeval size may differ between what Zig sees via @cImport
 * and what LWIP was compiled with, causing setsockopt(SO_RCVTIMEO) to return EINVAL.
 */

#ifndef SOCKET_HELPER_H
#define SOCKET_HELPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Set socket receive timeout
 *
 * @param fd Socket file descriptor
 * @param timeout_ms Timeout in milliseconds (0 to disable)
 * @return 0 on success, -1 on error
 */
int socket_set_recv_timeout(int fd, uint32_t timeout_ms);

/**
 * Set socket send timeout
 *
 * @param fd Socket file descriptor
 * @param timeout_ms Timeout in milliseconds (0 to disable)
 * @return 0 on success, -1 on error
 */
int socket_set_send_timeout(int fd, uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif

#endif // SOCKET_HELPER_H
