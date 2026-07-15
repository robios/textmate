# Prebuilt universal static library — pin and update procedure in README.md.
add_library(ghostty-vt STATIC IMPORTED GLOBAL)
set_target_properties(ghostty-vt PROPERTIES
	IMPORTED_LOCATION             "${CMAKE_CURRENT_SOURCE_DIR}/lib/libghostty-vt.a"
	INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/include"
	INTERFACE_COMPILE_DEFINITIONS "GHOSTTY_STATIC"
)
