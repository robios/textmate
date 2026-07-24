add_library(lsp STATIC)
file(GLOB _src src/*.mm src/*.cc)
target_sources(lsp PRIVATE ${_src})
textmate_framework(lsp)
target_link_libraries(lsp PUBLIC
  bundles document settings text ns io "-framework Cocoa")
target_include_directories(lsp PRIVATE "${CMAKE_SOURCE_DIR}/vendor")

textmate_add_tests(lsp)
