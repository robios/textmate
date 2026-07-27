add_library(markdown STATIC)
file(GLOB _src src/*.cc)
target_sources(markdown PRIVATE ${_src})
textmate_framework(markdown)
target_link_libraries(markdown PUBLIC cmark-gfm)

textmate_add_tests(markdown)
