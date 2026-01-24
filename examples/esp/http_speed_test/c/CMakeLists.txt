cmake_minimum_required(VERSION 3.16)

# The following lines of code are used to determine the current directory and set it as the project root.
get_filename_component(CURRENT_DIR ${CMAKE_CURRENT_LIST_FILE} DIRECTORY)
set(PROJECT_PATH ${CURRENT_DIR})
get_filename_component(PROJECT_NAME ${PROJECT_PATH} NAME)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(${PROJECT_NAME})
