# Builds maestro_render (shared library). Used standalone (see ../README.md) and from
# app/windows/CMakeLists.txt via add_subdirectory.
cmake_minimum_required(VERSION 3.15)
project(maestro_render LANGUAGES CXX)

# Always optimised, even in Debug app builds: unoptimised, a 4-min render takes ~60 s instead of ~4 s.
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_RELEASE}")

add_library(maestro_render SHARED maestro_render.cpp)
target_compile_features(maestro_render PRIVATE cxx_std_17)
target_include_directories(maestro_render PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../third_party")
if(MSVC)
  set_property(TARGET maestro_render PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
  # /bigobj: Signalsmith's templates. /EHsc: we catch bad_alloc. Third-party headers aren't warning-clean.
  target_compile_options(maestro_render PRIVATE /bigobj /EHsc /W3 /wd4244 /wd4267 /wd4305)
  target_compile_definitions(maestro_render PRIVATE _CRT_SECURE_NO_WARNINGS NOMINMAX WIN32_LEAN_AND_MEAN)
endif()
