#ifndef COMMAND_IGNORED_SETTINGS_H_QJ4M7XSD
#define COMMAND_IGNORED_SETTINGS_H_QJ4M7XSD

#include "parser.h"

namespace command
{
	// The settings an item asks for that its run location will not honour. A
	// terminal command owns a pty — TextMate feeds it no stdin and sees none of
	// its output — so the entire input/output axis is inert for it (the table in
	// run_location’s comment in parser.h).
	//
	// Returned as the plist keys themselves, so an editor can name what it is
	// warning about. Empty for an inProcess command, which honours all of them.
	//
	// A key counts as asked for when its parsed value differs from the default
	// for this kind of item, not when the key is merely present: the Bundle
	// Editor materialises input, outputLocation and their neighbours into every
	// command it opens, so presence would report a conflict against a command
	// that never left its defaults. Drag commands parse with different defaults
	// than regular ones, hence `dragCommand`.
	std::vector<std::string> ignored_settings (plist::dictionary_t const& plist, bool dragCommand);

} /* command */

#endif /* end of include guard: COMMAND_IGNORED_SETTINGS_H_QJ4M7XSD */
