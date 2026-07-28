# The bundles shipped in the app are content, not build targets — they are
# copied into Contents/SharedSupport/Bundles by Applications/TextMate. What is
# here is the test for the one piece of them we wrote: the plist shim that
# replaced Bundle Support's CoreFoundation C extension.
#
# --disable-gems matches how bin/tm_ruby runs bundle commands, so the test sees
# the same interpreter setup the shim has to work under.
add_test(NAME plist_shim
  COMMAND /usr/bin/ruby --disable-gems "${CMAKE_CURRENT_SOURCE_DIR}/tests/t_plist_shim.rb")

# TM_SUPPORT_PATH must not leak in from an enclosing TextMate command: the shim
# has to resolve its own vendored library without it, and the test asserts the
# behaviour a bare script would see.
set_tests_properties(plist_shim PROPERTIES ENVIRONMENT "TM_SUPPORT_PATH=")

# bin/ruby18 is on the path of every command with a ruby18 shebang — 43 bundles'
# worth — and bin/tm_ruby behind it decides which ruby that is, so the ways they
# can be invoked are worth pinning down.
add_test(NAME ruby_shims
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/tests/t_ruby_shims.sh")

# The file panel replaced a CocoaDialog call. $DIALOG is stubbed, so this checks
# the option mapping and the shape of the answer without a running TextMate —
# which is the part a live run would otherwise be the only way to see.
add_test(NAME file_panel
  COMMAND /usr/bin/ruby --disable-gems "${CMAKE_CURRENT_SOURCE_DIR}/tests/t_file_panel.rb")
