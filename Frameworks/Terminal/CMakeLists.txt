# rave: require OakAppKit OakFoundation OakSystem io ns settings text
add_library(Terminal STATIC)
file(GLOB _src src/*.cc src/*.mm)
target_sources(Terminal PRIVATE ${_src})
textmate_framework(Terminal)
target_link_libraries(Terminal PUBLIC
  OakAppKit OakFoundation OakSystem io ns settings text ghostty-vt "-framework Cocoa" "-framework CoreText")

textmate_add_tests(Terminal)
