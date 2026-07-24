# rave: require document lsp scm selection text io ns
add_library(AgentBridge STATIC)
file(GLOB _src src/*.cc src/*.mm)
target_sources(AgentBridge PRIVATE ${_src})
textmate_framework(AgentBridge)
target_link_libraries(AgentBridge PUBLIC
  OakSystem document lsp scm selection text io ns "-framework Cocoa" "-framework Network" "-framework Security")
target_include_directories(AgentBridge PRIVATE "${CMAKE_SOURCE_DIR}/vendor")

textmate_add_tests(AgentBridge)
