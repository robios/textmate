#ifndef AGENT_IDE_ROUTING_H_KQ73XZM8
#define AGENT_IDE_ROUTING_H_KQ73XZM8

#include "agent_routing_path.h"
#include <nlohmann/json.hpp>
#include <sys/types.h>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

// Which connected agent session a push of editor context belongs to.
//
// TextMate runs one WebSocket server for the whole app and advertises every
// open project in one lock file, so Claude Code sessions started in unrelated
// projects all connect to it. Pushes therefore have to be addressed, and the
// only identity the protocol offers is the pid in ‘ide_connected’, resolved to
// that process’ working directory. That directory is advisory routing input,
// not a captured window: it is matched against the projects that are open at
// the moment of each delivery, so opening and closing windows changes the
// answer by itself.
//
// Pure over plain values — paths and project roots in, a decision out —
// because the interesting part is the rule, and a rule that needed two project
// windows and two live CLI sessions to exercise would not be tested at all.
namespace agent_ide_routing
{
	// The open project containing ‘routing_path’, longest root first so a
	// checkout nested inside another project does not lose to its parent.
	// Empty when no open project contains it.
	//
	// Deliberately without the frontmost-window fallback that
	// ‘controllerForRoutingPath:’ applies: the whole point here is to tell “this
	// session is somewhere else” apart from “we do not know where this session
	// is”, which that fallback hides. A path that is a common parent of several
	// projects contains none of them and is therefore unresolved, matching
	// agent_routing_path::routes_to_project.
	inline std::string matching_project_root (std::string const& routing_path, std::vector<std::string> const& project_roots)
	{
		if(routing_path.empty() || routing_path.front() != '/')
			return std::string();

		std::string const path = agent_routing_path::normalize(routing_path);

		std::string res;
		for(std::string const& candidate : project_roots)
		{
			if(candidate.empty() || candidate.front() != '/')
				continue;

			std::string const root = agent_routing_path::normalize(candidate);
			if(root != path && !path::is_child(path, root))
				continue;
			if(root.size() > res.size())
				res = root;
		}
		return res;
	}

	// Should a push that originated in ‘origin_project’ reach a session whose
	// stored working directory is ‘session_cwd’?
	//
	// A session that cannot be placed — no working directory at all, or one
	// inside no open project — keeps the behaviour it had before any of this
	// existed and hears everything: it may well be the session the user is
	// talking to, and a silently unaddressed push is worse than a surplus one.
	// A session that can be placed is addressed strictly: its own project and
	// nothing else.
	//
	// Project paths are compared, never window identity, so two windows open on
	// the same project are one destination rather than two.
	inline bool delivers_to_session (std::string const& origin_project, std::string const& session_cwd, std::vector<std::string> const& project_roots)
	{
		std::string const root = matching_project_root(session_cwd, project_roots);
		if(root.empty())
			return true;
		return !origin_project.empty() && root == agent_routing_path::normalize(origin_project);
	}

	// The project a mention belongs to: where the mentioning process is, else
	// where the mentioned file is, else nowhere. The caller refuses a mention it
	// cannot place rather than sending it to sessions it knows are working
	// somewhere else (AgentBridge.mm).
	inline std::string mention_origin (std::string const& working_directory, std::string const& file_path, std::vector<std::string> const& project_roots)
	{
		std::string const res = matching_project_root(working_directory, project_roots);
		return res.empty() ? matching_project_root(file_path, project_roots) : res;
	}

	// Claude Code announces itself with ‘ide_connected’ carrying its own pid
	// (verified against CLI 2.1.233, which sends params:{pid:process.pid}).
	// Anything else — a float, zero or negative, a value too large for pid_t,
	// no params at all — names no process we can ask the kernel about and
	// leaves the connection unrouted.
	inline bool client_pid (nlohmann::json const& params, pid_t* out)
	{
		if(!out || !params.is_object() || !params.contains("pid"))
			return false;

		nlohmann::json const& value = params["pid"];
		if(!value.is_number_integer())
			return false;

		if(value.is_number_unsigned())
		{
			uint64_t const pid = value.get<uint64_t>();
			if(pid == 0 || pid > (uint64_t)std::numeric_limits<pid_t>::max())
				return false;
			*out = (pid_t)pid;
			return true;
		}

		int64_t const pid = value.get<int64_t>();
		if(pid <= 0 || pid > (int64_t)std::numeric_limits<pid_t>::max())
			return false;
		*out = (pid_t)pid;
		return true;
	}

	// Only ‘ide_connected’ installs a connection’s one-shot context seed.
	//
	// ‘notifications/initialized’ announces the same client and may arrive
	// first, but carries no pid: seeding on it would race the identity and send
	// the frontmost project’s selection to a session belonging to another
	// project — and marking the connection seeded at that point is exactly what
	// would stop the correct seed from following. A client that never sends
	// ‘ide_connected’ consequently gets no seed, only ordinary live pushes;
	// that is the cost of never guessing that a late identity will not arrive.
	inline bool announcement_installs_seed (std::string const& method)
	{
		return method == "ide_connected";
	}

} /* agent_ide_routing */

#endif /* AGENT_IDE_ROUTING_H_KQ73XZM8 */
