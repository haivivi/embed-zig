# ESP-SR (Speech Recognition) CMake configuration
#
# This module provides speech recognition related functionality using ESP-SR library.
# Currently includes:
# - AEC (Acoustic Echo Cancellation)
#
# Future additions:
# - VAD (Voice Activity Detection)
# - WakeWord detection
# - ASR (Automatic Speech Recognition)

get_filename_component(_SR_DIR "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)

# AEC C helper sources
set(SR_C_SOURCES
    "${_SR_DIR}/aec_helper.c"
)

# ESP-SR component is required
set(SR_REQUIRES
    esp-sr
    heap
)

# Force linker to include SR helper functions
set(SR_FORCE_LINK
    aec_helper_force_link
    aec_helper_create
    aec_helper_process
    aec_helper_get_chunksize
    aec_helper_get_total_channels
    aec_helper_destroy
    aec_helper_alloc_buffer
    aec_helper_free_buffer
)
