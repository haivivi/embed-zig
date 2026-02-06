# Event helper C sources
set(EVENT_SRCS
    ${CMAKE_CURRENT_LIST_DIR}/event_helper.c
)

set(EVENT_INCLUDE_DIRS
    ${CMAKE_CURRENT_LIST_DIR}
)

# Force link symbols
set(EVENT_FORCE_LINK
    event_helper_init
    event_helper_deinit
    event_helper_is_initialized
)

# Setup function - called after idf_component_register()
function(event_setup_includes)
    target_include_directories(${COMPONENT_LIB} PUBLIC ${EVENT_INCLUDE_DIRS})
endfunction()

message(STATUS "[event] C sources: ${EVENT_SRCS}")
message(STATUS "[event] Include dirs: ${EVENT_INCLUDE_DIRS}")
