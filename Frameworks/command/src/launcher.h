#ifndef COMMAND_LAUNCHER_H_KX2R7VME
#define COMMAND_LAUNCHER_H_KX2R7VME

#include "parser.h"
#include <bundles/bundles.h>

namespace command
{
	// The semantic class a bundle command declares to be offered as a way of
	// starting something in the terminal. Deliberately not under ‘callback.’ —
	// those are events TextMate fires, and this is not one.
	//
	// A prefix, as semanticClass matching always is: a command declaring
	// ‘terminal.launcher.rails’ answers to this, which is the same convention
	// ‘callback.document.will-save’ and friends rely on.
	extern std::string const kSemanticClassTerminalLauncher;

	// The launchers that apply in `scope`. A caller presenting these has only to
	// order them; what belongs in the list is decided here.
	std::vector<bundles::item_ptr> terminal_launchers (scope::context_t const& scope);

} /* command */

#endif /* end of include guard: COMMAND_LAUNCHER_H_KX2R7VME */
