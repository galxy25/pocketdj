cmake_minimum_required(VERSION 3.22.1)
project(pdjdsp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(oboe REQUIRED CONFIG)

# No -ffast-math: the Kotlin kernel mirrors are checked against these to 1e-5.
add_library(pdjdsp SHARED
    jni.cpp
    fx_kernels.cpp
    mixer.cpp
    sf2_voice.cpp
    stretch.cpp
    stretch_rt.cpp
    oboe_sink.cpp)

target_include_directories(pdjdsp PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(pdjdsp PRIVATE -O3 -Wall)
target_link_options(pdjdsp PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384")
target_link_libraries(pdjdsp PRIVATE oboe::oboe log android)
