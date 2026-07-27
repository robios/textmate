add_executable(tm_markdown)
file(GLOB _src src/*.cc)
target_sources(tm_markdown PRIVATE ${_src})
target_link_libraries(tm_markdown PRIVATE markdown ${TEXTMATE_DEBUG_LIBS})
