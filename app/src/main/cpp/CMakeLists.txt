cmake_minimum_required(VERSION 3.10)
project(vdextra LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Vendored rather than depending on the host Xposed framework's hook_func - see
# nim/vdextra.nim for why. https://github.com/JingMatrix/Dobby, Apache-2.0.
set(DOBBY_BUILD_EXAMPLE OFF CACHE BOOL "" FORCE)
set(DOBBY_BUILD_TEST OFF CACHE BOOL "" FORCE)
add_subdirectory(dobby)

# Nim compiles to C rather than straight to an object file, so it slots into this build as a
# code generator: it emits .c into a cache directory and the NDK toolchain compiles those like
# any other source. That keeps one compiler (the NDK's clang) responsible for the actual ABI,
# sysroot and flags, instead of asking Nim to cross-compile and link an .so itself.
#
# Nim runs at *configure* time because CMake needs the generated file list before it can define
# the target. Builds here are clean CI builds, so that is sufficient; when iterating locally,
# re-run CMake configure after editing a .nim file.
set(NIM_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../nim)
set(NIM_CACHE ${CMAKE_CURRENT_BINARY_DIR}/nimcache)

find_program(NIM_EXE nim)
if(NOT NIM_EXE)
  message(FATAL_ERROR
    "nim not found on PATH. The native code is part Nim; install Nim (choosenim or a distro "
    "package) before building. CI does this in .github/workflows/release.yml.")
endif()

# nimbase.h ships in Nim's own lib directory and is included by every generated file. Ask Nim
# where that is rather than deriving it from the binary's path, which breaks when nim is a shim
# or symlink. Hints go to stderr, so stdout here is pure JSON.
# (string(JSON) needs CMake 3.19+; the NDK ships 3.22.)
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

# --mm:arc keeps memory management deterministic and refcounted with no stop-the-world
# collector, which matters because our code is entered from Mono and Android threads this
# runtime never created. --threads:on makes the refcounts and thread locals thread-safe.
execute_process(
  COMMAND ${NIM_EXE} c
          --compileOnly:on
          --nimcache:${NIM_CACHE}
          --os:android --cpu:arm64 --cc:clang
          --app:lib --noMain:on
          # Mono drives implicit null checks, GC write barriers and thread suspension through
          # SIGSEGV, so Nim must not install its own handlers: hijacking them turned the first
          # signal Mono would have handled itself into a Nim fatal error and a silent quit().
          -d:noSignalHandler
          --mm:arc --threads:on
          -d:release
          ${NIM_SRC_DIR}/vdextra.nim
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
# Nothing in this target is C++ any more, but Dobby is, so link through the C++ driver or the
# C++ runtime it needs is left out.
set_target_properties(vdextra PROPERTIES LINKER_LANGUAGE CXX)
# Flags Nim passes to its own C compiler: its generated code is not warning-clean by design,
# relies on this aliasing rule, and needs -pthread because it is built with --threads:on.
set_source_files_properties(${NIM_GENERATED_C} PROPERTIES
  COMPILE_OPTIONS "-w;-fno-strict-aliasing;-pthread")
target_link_libraries(vdextra log dl dobby_static)
