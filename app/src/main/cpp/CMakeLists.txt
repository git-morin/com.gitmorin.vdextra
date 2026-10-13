cmake_minimum_required(VERSION 3.10)
project(vdextra LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(vdextra SHARED native.cpp)
target_compile_options(vdextra PRIVATE -std=c++17 -fPIC -O2)
target_link_libraries(vdextra log dl)
