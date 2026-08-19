# rave: require OakAppKit OakFoundation OakSystem io ns settings text
add_library(Terminal STATIC)
file(GLOB _src src/*.cc src/*.mm)
target_sources(Terminal PRIVATE ${_src})
textmate_framework(Terminal)
target_link_libraries(Terminal PUBLIC
  OakAppKit OakFoundation OakSystem io ns settings text ghostty-vt "-framework Cocoa" "-framework CoreText")

# The trampoline PTYController spawns in place of the terminal's shell (see
# helper/TextMatePTYHelper.c). PTYController resolves it as a sibling of the
# running executable, so it must land beside both the app binary (embedded into
# Contents/MacOS by Applications/TextMate) and the test runner — which it does
# here, since both build into this directory.
add_executable(TextMatePTYHelper helper/TextMatePTYHelper.c)
target_include_directories(TextMatePTYHelper PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")

# Nothing inherited from the tree-wide options belongs in this one: it is a
# straight line of syscalls with no allocation, running for a few milliseconds
# before it becomes the user's shell. -ObjC/-fobjc-link-runtime would load the
# ObjC runtime for nothing, and ASan (debug) reserves the address space
# libmalloc wants, which makes libmalloc warn on stderr — here, the terminal the
# user is about to see. Clearing LINK_OPTIONS drops the inherited link flags;
# -fno-sanitize=address comes last on both command lines, so it wins.
target_compile_options(TextMatePTYHelper PRIVATE -fno-sanitize=address)
set_target_properties(TextMatePTYHelper PROPERTIES LINK_OPTIONS "-fno-sanitize=address")

textmate_add_tests(Terminal)
if(TARGET Terminal_tests)
  # The stand-in for a shell that the PTY tests spawn (tests/pty_probe.c): a
  # shell reacts to the terminal state under test instead of reporting it. It
  # lands beside the test runner, which passes it as PTYController's target
  # path, and is kept out of ASan for the helper's reasons — its records travel
  # over the pty the tests parse, and libmalloc's warning would travel with
  # them.
  add_executable(tm_pty_probe tests/pty_probe.c)
  target_compile_options(tm_pty_probe PRIVATE -fno-sanitize=address)
  set_target_properties(tm_pty_probe PROPERTIES LINK_OPTIONS "-fno-sanitize=address")

  add_dependencies(Terminal_tests TextMatePTYHelper tm_pty_probe)
endif()
