# rave: require document lsp scm selection settings text io ns
add_library(AgentBridge STATIC)
file(GLOB _src src/*.cc src/*.mm)
target_sources(AgentBridge PRIVATE ${_src})
textmate_framework(AgentBridge)
target_link_libraries(AgentBridge PUBLIC
  OakSystem document lsp scm selection settings text io ns "-framework Cocoa" "-framework Network" "-framework Security")
target_include_directories(AgentBridge PRIVATE "${CMAKE_SOURCE_DIR}/vendor")

textmate_add_tests(AgentBridge)

# agent_tools.h is pure C++ over nlohmann json (it is also compiled into the
# tm_agent CLI, which does not link this framework) — the tests reach it
# directly, so they need the vendor headers the framework keeps private. The
# src directory itself is on the path for the tm_agent headers under test,
# which include agent_tools.h the way the CLI does.
if(TARGET AgentBridge_tests)
  target_include_directories(AgentBridge_tests PRIVATE
    "${CMAKE_SOURCE_DIR}/vendor"
    "${CMAKE_CURRENT_SOURCE_DIR}/src")
endif()
