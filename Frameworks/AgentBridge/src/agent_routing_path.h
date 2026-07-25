#ifndef AGENT_ROUTING_PATH_H_VG8BXKCF
#define AGENT_ROUTING_PATH_H_VG8BXKCF

#include <io/path.h>
#include <string>

// macOS exposes /var, /tmp, and /etc as symlinks into /private. A path coming
// from getcwd(3) is commonly resolved (/private/var/…), while Cocoa may retain
// the spelling used to open a document (/var/…). Routing must treat those as
// the same project without doing filesystem I/O on TextMate's main thread.
namespace agent_routing_path
{
	inline std::string normalize (std::string const& value)
	{
		std::string const normalized = path::normalize(value);
		for(std::string const& alias : { std::string("/var"), std::string("/tmp"), std::string("/etc") })
		{
			if(normalized == alias || normalized.compare(0, alias.size() + 1, alias + "/") == 0)
				return "/private" + normalized;
		}
		return normalized;
	}

	// Directional on purpose: a process inside a project routes to it, but a
	// common parent of multiple projects is ambiguous and must not.
	inline bool routes_to_project (std::string const& routing_path, std::string const& project_root)
	{
		std::string const path = normalize(routing_path);
		std::string const root = normalize(project_root);
		return path == root || path::is_child(path, root);
	}
}

#endif /* AGENT_ROUTING_PATH_H_VG8BXKCF */
