# Runtime support for freestanding environment
# Provides compiler builtins like __udivti3 (128-bit division)

set(RUNTIME_C_SOURCES
    ${CMAKE_CURRENT_LIST_DIR}/udivti3.c
)

# No external dependencies
set(RUNTIME_REQUIRES
)

# Force link these symbols
set(RUNTIME_FORCE_LINK
    runtime_force_link
)
