// fast_add: int64_t fast_add(int64_t a, int64_t b)
// aarch64: a in x0, b in x1, return in x0

.global _fast_add
.p2align 2

_fast_add:
    add x0, x0, x1
    ret
