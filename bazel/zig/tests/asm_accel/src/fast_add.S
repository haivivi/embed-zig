// fast_add: int64_t fast_add(int64_t a, int64_t b)
// Multi-arch: aarch64 and x86_64

#if defined(__aarch64__)

.global _fast_add
.global fast_add
.p2align 2

_fast_add:
fast_add:
    add x0, x0, x1
    ret

#elif defined(__x86_64__)

.global fast_add
.p2align 4

fast_add:
    leaq (%rdi, %rsi), %rax
    retq

#else
#error "Unsupported architecture for fast_add ASM"
#endif
