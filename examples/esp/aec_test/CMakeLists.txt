# AEC Test - Uses esp_codec_dev for codec init

cmake_minimum_required(VERSION 3.16)

set(EXTRA_COMPONENT_DIRS
    $ENV{ADF_PATH}/components/esp-sr
    $ENV{ADF_PATH}/components/esp_codec_dev
)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(aec_test)
