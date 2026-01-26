# I2C module for ESP Zig
# Include this in main/CMakeLists.txt if using I2C
#
# Provides:
#   I2C_C_SOURCES - C helper sources
#   I2C_FORCE_LINK - Force link symbols

# C helper sources
file(GLOB I2C_C_SOURCES "${CMAKE_CURRENT_LIST_DIR}/i2c_helper.c")

# Force link symbols
set(I2C_FORCE_LINK
    i2c_helper_init
    i2c_helper_deinit
    i2c_helper_write_read
    i2c_helper_write
    i2c_helper_read
)
