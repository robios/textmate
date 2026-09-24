add_library(SoftwareUpdate STATIC)
file(GLOB _src src/*.mm)
target_sources(SoftwareUpdate PRIVATE ${_src})
textmate_framework(SoftwareUpdate)
target_link_libraries(SoftwareUpdate PUBLIC
  OakAppKit OakFoundation OakSystem BundlesManager "-framework Cocoa" "-framework Security")

textmate_add_tests(SoftwareUpdate)
