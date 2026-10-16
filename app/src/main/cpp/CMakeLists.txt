cmake_minimum_required(VERSION 3.10)
project(vdextra LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(DOBBY_BUILD_EXAMPLE OFF CACHE BOOL "" FORCE)
set(DOBBY_BUILD_TEST OFF CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(dobby
  GIT_REPOSITORY https://github.com/JingMatrix/Dobby.git
  GIT_TAG 05a09ac6807a6bb1726350e40ea4b127c1c79809
)
FetchContent_MakeAvailable(dobby)
set(NIM_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../nim)
set(NIM_CACHE ${CMAKE_CURRENT_BINARY_DIR}/nimcache)

find_program(NIM_EXE nim)
if(NOT NIM_EXE)
  message(FATAL_ERROR
    "nim not found on PATH. The native code is part Nim; install Nim (choosenim or a distro "
    "package) before building. CI does this in .github/workflows/release.yml.")
endif()

execute_process(
  COMMAND ${NIM_EXE} dump --dump.format:json ${NIM_SRC_DIR}/vdextra.nim
  OUTPUT_VARIABLE NIM_DUMP
  ERROR_QUIET
  RESULT_VARIABLE NIM_DUMP_RESULT)
if(NOT NIM_DUMP_RESULT EQUAL 0)
  message(FATAL_ERROR "'nim dump' failed - is the Nim install usable?")
endif()
string(JSON NIM_LIB_DIR GET "${NIM_DUMP}" libpath)
if(NOT NIM_LIB_DIR OR NOT EXISTS ${NIM_LIB_DIR}/nimbase.h)
  message(FATAL_ERROR "no nimbase.h under Nim's reported libpath ('${NIM_LIB_DIR}')")
endif()

execute_process(
  COMMAND ${NIM_EXE} c --compileOnly:on --nimcache:${NIM_CACHE} ${NIM_SRC_DIR}/vdextra.nim
  RESULT_VARIABLE NIM_RESULT
  OUTPUT_VARIABLE NIM_OUTPUT
  ERROR_VARIABLE NIM_OUTPUT)
if(NOT NIM_RESULT EQUAL 0)
  message(FATAL_ERROR "nim codegen failed:\n${NIM_OUTPUT}")
endif()

file(GLOB NIM_GENERATED_C ${NIM_CACHE}/*.c)
if(NOT NIM_GENERATED_C)
  message(FATAL_ERROR "nim produced no C sources in ${NIM_CACHE}")
endif()
list(LENGTH NIM_GENERATED_C NIM_GENERATED_COUNT)
message(STATUS "nim: generated ${NIM_GENERATED_COUNT} C source(s) for arm64 in ${NIM_CACHE}")

add_library(vdextra SHARED init.c ${NIM_GENERATED_C})
target_include_directories(vdextra PRIVATE ${NIM_LIB_DIR} ${NIM_SRC_DIR})
target_compile_options(vdextra PRIVATE -fPIC -O2)
set_target_properties(vdextra PROPERTIES LINKER_LANGUAGE CXX)
set_source_files_properties(${NIM_GENERATED_C} PROPERTIES
  COMPILE_OPTIONS "-w;-fno-strict-aliasing;-pthread")
target_link_libraries(vdextra log dl dobby_static)
