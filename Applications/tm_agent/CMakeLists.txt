add_executable(tm_agent)
file(GLOB _src src/*.cc)
target_sources(tm_agent PRIVATE ${_src})
target_link_libraries(tm_agent PRIVATE ${TEXTMATE_DEBUG_LIBS})
# The MCP shim answers tools/list offline, out of the same table the in-app
# WebSocket server advertises from (Frameworks/AgentBridge/src/agent_tools.h) —
# a pure header over nlohmann json, so the CLI compiles it without linking the
# framework or dragging in Cocoa.
target_include_directories(tm_agent PRIVATE
  "${CMAKE_SOURCE_DIR}/vendor"
  "${CMAKE_SOURCE_DIR}/Frameworks/AgentBridge/src")
target_compile_definitions(tm_agent PRIVATE "TEXTMATE_VERSION_STRING=\"${TEXTMATE_VERSION}\"")
