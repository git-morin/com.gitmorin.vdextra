cmake_minimum_required(VERSION 3.10)
project(vdextra LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Vendored (not a hook_func dependency on the host Xposed framework - see native.cpp
# for why): https://github.com/JingMatrix/Dobby, Apache-2.0.
set(DOBBY_BUILD_EXAMPLE OFF CACHE BOOL "" FORCE)
set(DOBBY_BUILD_TEST OFF CACHE BOOL "" FORCE)
add_subdirectory(dobby)

add_library(vdextra SHARED native.cpp)
target_compile_options(vdextra PRIVATE -std=c++17 -fPIC -O2)
target_link_libraries(vdextra log dl dobby_static)
