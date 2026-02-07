/**
 * Socket Helper Implementation
 *
 * Uses C-level struct timeval to ensure type compatibility with LWIP.
 */

#include "socket_helper.h"
#include <sys/time.h>
#include <lwip/sockets.h>

int socket_set_recv_timeout(int fd, uint32_t timeout_ms) {
    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

int socket_set_send_timeout(int fd, uint32_t timeout_ms) {
    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    return setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}
