#include "launcher.h"

namespace command
{
	std::string const kSemanticClassTerminalLauncher = "terminal.launcher";

	std::vector<bundles::item_ptr> terminal_launchers (scope::context_t const& scope)
	{
		std::vector<bundles::item_ptr> res;

		// filter = false: bundles::query otherwise keeps only the highest scope
		// rank, so one launcher scoped to the current language would carry the
		// cutoff away with it and hide every general one. Scope selectors still
		// decide what applies here; they no longer decide it for each other.
		for(auto const& item : bundles::query(bundles::kFieldSemanticClass, kSemanticClassTerminalLauncher, scope, bundles::kItemTypeCommand, oak::uuid_t(), false /* filter */))
		{
			// The class alone is not the promise. A command carrying it while
			// leaving runLocation at inProcess still runs inside TextMate, so
			// offering it as a launcher would advertise a terminal tab that never
			// opens; the parsed value decides, not the declaration.
			if(item->hidden_from_user() || parse_command(item).run_location != run_location::terminal)
				continue;

			res.push_back(item);
		}

		return res;
	}

} /* command */
