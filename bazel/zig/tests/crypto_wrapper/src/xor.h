#ifndef XOR_H
#define XOR_H

#include <stddef.h>
#include <stdint.h>

// XOR two byte buffers: dst[i] ^= src[i] for i in [0, len)
void xor_bytes(uint8_t* dst, const uint8_t* src, size_t len);

#endif
