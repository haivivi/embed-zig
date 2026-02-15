/**
 * bk_zig_socket_helper.c — LWIP socket wrappers for Zig interop.
 *
 * BK7258 uses standard LWIP, so the socket API is nearly identical to ESP.
 * This helper provides clean C functions callable from Zig without
 * needing to @cImport the complex Armino/LWIP headers.
 */

#include <os/os.h>
#include "lwip/sockets.h"
#include "lwip/netdb.h"
#include <errno.h>

/* ========================================================================
 * Socket creation
 * ======================================================================== */

int bk_zig_socket_tcp(void) {
    return socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
}

int bk_zig_socket_udp(void) {
    return socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
}

void bk_zig_socket_close(int fd) {
    close(fd);
}

/* ========================================================================
 * Client operations
 * ======================================================================== */

int bk_zig_socket_connect(int fd, unsigned int ip_be, unsigned short port) {
    struct sockaddr_in sa;
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = ip_be;
    memset(sa.sin_zero, 0, sizeof(sa.sin_zero));
    return connect(fd, (struct sockaddr *)&sa, sizeof(sa));
}

int bk_zig_socket_send(int fd, const void *data, unsigned int len) {
    return send(fd, data, len, 0);
}

int bk_zig_socket_recv(int fd, void *buf, unsigned int len) {
    return recv(fd, buf, len, 0);
}

/* ========================================================================
 * UDP operations
 * ======================================================================== */

int bk_zig_socket_sendto(int fd, unsigned int ip_be, unsigned short port,
                         const void *data, unsigned int len) {
    struct sockaddr_in sa;
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = ip_be;
    memset(sa.sin_zero, 0, sizeof(sa.sin_zero));
    return sendto(fd, data, len, 0, (struct sockaddr *)&sa, sizeof(sa));
}

int bk_zig_socket_recvfrom(int fd, void *buf, unsigned int len,
                           unsigned int *out_ip_be, unsigned short *out_port) {
    struct sockaddr_in sa;
    socklen_t sa_len = sizeof(sa);
    int ret = recvfrom(fd, buf, len, 0, (struct sockaddr *)&sa, &sa_len);
    if (ret >= 0 && out_ip_be && out_port) {
        *out_ip_be = sa.sin_addr.s_addr;
        *out_port = ntohs(sa.sin_port);
    }
    return ret;
}

/* ========================================================================
 * Server operations
 * ======================================================================== */

int bk_zig_socket_bind(int fd, unsigned short port) {
    struct sockaddr_in sa;
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = INADDR_ANY;
    memset(sa.sin_zero, 0, sizeof(sa.sin_zero));
    return bind(fd, (struct sockaddr *)&sa, sizeof(sa));
}

int bk_zig_socket_listen(int fd, int backlog) {
    return listen(fd, backlog);
}

int bk_zig_socket_accept(int fd, unsigned int *out_ip_be, unsigned short *out_port) {
    struct sockaddr_in sa;
    socklen_t sa_len = sizeof(sa);
    int ret = accept(fd, (struct sockaddr *)&sa, &sa_len);
    if (ret >= 0 && out_ip_be && out_port) {
        *out_ip_be = sa.sin_addr.s_addr;
        *out_port = ntohs(sa.sin_port);
    }
    return ret;
}

/* ========================================================================
 * Socket options
 * ======================================================================== */

int bk_zig_socket_set_recv_timeout(int fd, unsigned int timeout_ms) {
    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

int bk_zig_socket_set_send_timeout(int fd, unsigned int timeout_ms) {
    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    return setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

int bk_zig_socket_set_reuse_addr(int fd, int enable) {
    return setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable, sizeof(enable));
}

int bk_zig_socket_set_nodelay(int fd, int enable) {
    return setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enable, sizeof(enable));
}

/* ========================================================================
 * Non-blocking / query
 * ======================================================================== */

int bk_zig_socket_set_nonblocking(int fd, int enable) {
    unsigned long val = enable ? 1 : 0;
    return ioctlsocket(fd, FIONBIO, &val);
}

int bk_zig_socket_get_bound_port(int fd) {
    struct sockaddr_in addr;
    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &len) != 0) return -1;
    return ntohs(addr.sin_port);
}

/* ========================================================================
 * Error handling
 * ======================================================================== */

int bk_zig_socket_errno(void) {
    return errno;
}
