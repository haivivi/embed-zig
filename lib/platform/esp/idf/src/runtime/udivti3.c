/**
 * 128-bit integer division/modulo runtime support for ESP32 freestanding environment.
 * 
 * These functions are normally provided by libgcc or compiler-rt, but in freestanding
 * mode they must be provided manually. The Zig compiler may generate calls to these
 * functions for 128-bit integer operations.
 * 
 * Since ESP32 is a 32-bit architecture that doesn't support __int128, we use
 * a struct to represent 128-bit integers and implement division manually.
 */

#include <stdint.h>

// 128-bit unsigned integer as struct (low-high order for little-endian)
typedef struct {
    uint64_t lo;
    uint64_t hi;
} uint128_t;

// 128-bit signed integer as struct
typedef struct {
    uint64_t lo;
    int64_t hi;
} int128_t;

// Helper: check if a is zero
static inline int is_zero(uint128_t a) {
    return a.lo == 0 && a.hi == 0;
}

// Helper: check if a < b
static inline int less_than(uint128_t a, uint128_t b) {
    if (a.hi != b.hi) return a.hi < b.hi;
    return a.lo < b.lo;
}

// Helper: check if a == b
static inline int equal(uint128_t a, uint128_t b) {
    return a.lo == b.lo && a.hi == b.hi;
}

// Helper: subtract b from a (a - b)
static inline uint128_t sub128(uint128_t a, uint128_t b) {
    uint128_t result;
    result.lo = a.lo - b.lo;
    result.hi = a.hi - b.hi;
    if (a.lo < b.lo) {
        result.hi--; // borrow
    }
    return result;
}

// Helper: shift left by 1
static inline uint128_t shl1(uint128_t a) {
    uint128_t result;
    result.hi = (a.hi << 1) | (a.lo >> 63);
    result.lo = a.lo << 1;
    return result;
}

// Helper: shift right by 1
static inline uint128_t shr1(uint128_t a) {
    uint128_t result;
    result.lo = (a.lo >> 1) | (a.hi << 63);
    result.hi = a.hi >> 1;
    return result;
}

// Helper: count leading zeros in 64-bit
static inline int clz64(uint64_t x) {
    if (x == 0) return 64;
    return __builtin_clzll(x);
}

// Helper: count leading zeros in 128-bit
static inline int clz128(uint128_t x) {
    if (x.hi != 0) {
        return clz64(x.hi);
    } else {
        return 64 + clz64(x.lo);
    }
}

// Internal: 128-bit unsigned division returning both quotient and remainder
static void udivmod128(uint128_t a, uint128_t b, uint128_t *quotient, uint128_t *remainder) {
    // Handle division by zero
    if (is_zero(b)) {
        if (quotient) { quotient->lo = 0; quotient->hi = 0; }
        if (remainder) { remainder->lo = 0; remainder->hi = 0; }
        return;
    }
    
    // Handle a < b
    if (less_than(a, b)) {
        if (quotient) { quotient->lo = 0; quotient->hi = 0; }
        if (remainder) *remainder = a;
        return;
    }
    
    // Handle a == b
    if (equal(a, b)) {
        if (quotient) { quotient->lo = 1; quotient->hi = 0; }
        if (remainder) { remainder->lo = 0; remainder->hi = 0; }
        return;
    }
    
    // Binary long division
    int shift = clz128(b) - clz128(a);
    uint128_t divisor = b;
    
    // Shift divisor left
    for (int i = 0; i < shift; i++) {
        divisor = shl1(divisor);
    }
    
    uint128_t q = {0, 0};
    uint128_t r = a;
    
    for (int i = 0; i <= shift; i++) {
        q = shl1(q);
        if (!less_than(r, divisor)) {
            r = sub128(r, divisor);
            q.lo |= 1;
        }
        divisor = shr1(divisor);
    }
    
    if (quotient) *quotient = q;
    if (remainder) *remainder = r;
}

/**
 * 128-bit unsigned integer division
 * Returns: a / b
 * 
 * ABI: 128-bit values are passed/returned as struct with two 64-bit parts
 */
uint128_t __udivti3(uint128_t a, uint128_t b) {
    uint128_t q;
    udivmod128(a, b, &q, (uint128_t *)0);
    return q;
}

/**
 * 128-bit unsigned integer modulo
 * Returns: a % b
 */
uint128_t __umodti3(uint128_t a, uint128_t b) {
    uint128_t r;
    udivmod128(a, b, (uint128_t *)0, &r);
    return r;
}

/**
 * 128-bit signed integer division
 * Returns: a / b
 */
int128_t __divti3(int128_t a, int128_t b) {
    int neg = 0;
    uint128_t ua, ub;
    
    // Handle negative a
    if (a.hi < 0) {
        neg = !neg;
        // Two's complement negation
        ua.lo = ~a.lo + 1;
        ua.hi = ~a.hi + (ua.lo == 0 ? 1 : 0);
    } else {
        ua.lo = a.lo;
        ua.hi = (uint64_t)a.hi;
    }
    
    // Handle negative b
    if (b.hi < 0) {
        neg = !neg;
        ub.lo = ~b.lo + 1;
        ub.hi = ~b.hi + (ub.lo == 0 ? 1 : 0);
    } else {
        ub.lo = b.lo;
        ub.hi = (uint64_t)b.hi;
    }
    
    uint128_t q = __udivti3(ua, ub);
    
    int128_t result;
    if (neg) {
        // Negate result
        result.lo = ~q.lo + 1;
        result.hi = ~q.hi + (result.lo == 0 ? 1 : 0);
    } else {
        result.lo = q.lo;
        result.hi = (int64_t)q.hi;
    }
    return result;
}

/**
 * 128-bit signed integer modulo
 * Returns: a % b
 */
int128_t __modti3(int128_t a, int128_t b) {
    int neg = (a.hi < 0);
    uint128_t ua, ub;
    
    // Handle negative a
    if (a.hi < 0) {
        ua.lo = ~a.lo + 1;
        ua.hi = ~a.hi + (ua.lo == 0 ? 1 : 0);
    } else {
        ua.lo = a.lo;
        ua.hi = (uint64_t)a.hi;
    }
    
    // Handle negative b
    if (b.hi < 0) {
        ub.lo = ~b.lo + 1;
        ub.hi = ~b.hi + (ub.lo == 0 ? 1 : 0);
    } else {
        ub.lo = b.lo;
        ub.hi = (uint64_t)b.hi;
    }
    
    uint128_t r = __umodti3(ua, ub);
    
    int128_t result;
    if (neg) {
        result.lo = ~r.lo + 1;
        result.hi = ~r.hi + (result.lo == 0 ? 1 : 0);
    } else {
        result.lo = r.lo;
        result.hi = (int64_t)r.hi;
    }
    return result;
}

// Force linker to include these symbols
void runtime_force_link(void) {
    (void)__udivti3;
    (void)__umodti3;
    (void)__divti3;
    (void)__modti3;
}
