# cmark-gfm 0.29.0.gfm.13 (github/cmark-gfm), core library + GFM extensions.
# CLI, tests, and shared-library machinery are omitted; the generated headers
# (config.h, export, version) are committed under include/ instead of being
# produced by CMake feature checks — see the comments in those files.
add_library(cmark-gfm STATIC)

file(GLOB _src src/*.c)
file(GLOB _ext extensions/*.c)
target_sources(cmark-gfm PRIVATE ${_src} ${_ext})

target_include_directories(cmark-gfm PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/src"
  "${CMAKE_CURRENT_SOURCE_DIR}/extensions")

target_compile_options(cmark-gfm PRIVATE
  -Wno-comma
  -Wno-shorten-64-to-32
  -Wno-sign-compare
  -Wno-unused-function)
