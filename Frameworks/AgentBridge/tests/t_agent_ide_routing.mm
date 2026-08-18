#import "../src/agent_ide_routing.h"
#include <map>
#include <set>

// One WebSocket server serves every Claude Code session on the machine, so a
// push has to be addressed or it reaches sessions working on other projects —
// the bug this rule exists to fix, observed as project B’s files appearing in
// project A’s conversation. The rule is pure so it can be tested here rather
// than only with two windows and two live CLI sessions.

static std::vector<std::string> const kTwoProjects = { "/Users/me/projects/alpha", "/Users/me/projects/beta" };

void test_matching_project_root_contains_the_path ()
{
	// The root itself, and anything inside it.
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/Users/me/projects/alpha", kTwoProjects), "/Users/me/projects/alpha");
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/Users/me/projects/alpha/src/main.cc", kTwoProjects), "/Users/me/projects/alpha");
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/Users/me/projects/beta", kTwoProjects), "/Users/me/projects/beta");

	// A sibling whose name merely starts with a project’s is not inside it.
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/Users/me/projects/alpha-fork/x.cc", kTwoProjects), "");
}

void test_matching_project_root_prefers_the_longest_root ()
{
	// A checkout inside another project answers for itself, whichever order the
	// windows are in — the parent would otherwise swallow every nested repo.
	std::vector<std::string> const nested = { "/repo", "/repo/vendor/library" };
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/repo/vendor/library/src", nested), "/repo/vendor/library");
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/repo/src", nested), "/repo");

	std::vector<std::string> const reversed = { "/repo/vendor/library", "/repo" };
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/repo/vendor/library/src", reversed), "/repo/vendor/library");
}

void test_matching_project_root_without_a_match ()
{
	// A common parent of two projects contains neither: it does not identify one
	// project, so it identifies none.
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/Users/me/projects", kTwoProjects), "");

	// Outside every project, no path at all, a relative path, and a project list
	// that has since lost the routed window — all unresolved rather than guessed.
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/Users/me/Desktop", kTwoProjects), "");
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("", kTwoProjects), "");
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("projects/alpha", kTwoProjects), "");
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/Users/me/projects/alpha", { }), "");
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/Users/me/projects/alpha", { "/Users/me/projects/beta" }), "");
}

void test_matching_project_root_across_macos_path_aliases ()
{
	// getcwd(3) reports the resolved path while a window may keep the spelling
	// the project was opened under; /var, /tmp and /etc are the same directory.
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/private/var/folders/work/repo/src", { "/var/folders/work/repo" }), "/private/var/folders/work/repo");
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/tmp/repo", { "/private/tmp/repo" }), "/private/tmp/repo");
	OAK_ASSERT_EQ(agent_ide_routing::matching_project_root("/various/repo", { "/various/repo" }), "/various/repo"); // not an alias
}

void test_delivery_to_unplaceable_sessions ()
{
	std::string const origin = "/Users/me/projects/alpha";

	// No identity at all: the client sent no usable pid, so it keeps the
	// frontmost-window behaviour it had before any of this existed.
	OAK_ASSERT(agent_ide_routing::delivers_to_session(origin, "", kTwoProjects));

	// An identity that names no open project — a session started outside every
	// project, or one whose project window has since closed — is equally
	// unplaceable and equally eligible.
	OAK_ASSERT(agent_ide_routing::delivers_to_session(origin, "/Users/me/Desktop", kTwoProjects));
	OAK_ASSERT(agent_ide_routing::delivers_to_session(origin, "/Users/me/projects/beta", { "/Users/me/projects/alpha" }));

	// A parent of both projects is ambiguous, which is unplaceable too.
	OAK_ASSERT(agent_ide_routing::delivers_to_session(origin, "/Users/me/projects", kTwoProjects));
}

void test_delivery_to_placed_sessions ()
{
	std::string const origin = "/Users/me/projects/alpha";

	OAK_ASSERT(agent_ide_routing::delivers_to_session(origin, "/Users/me/projects/alpha", kTwoProjects));
	OAK_ASSERT(agent_ide_routing::delivers_to_session(origin, "/Users/me/projects/alpha/src", kTwoProjects));

	// The whole point: a session working on the other project hears nothing.
	OAK_ASSERT(!agent_ide_routing::delivers_to_session(origin, "/Users/me/projects/beta", kTwoProjects));
	OAK_ASSERT(!agent_ide_routing::delivers_to_session(origin, "/Users/me/projects/beta/lib", kTwoProjects));

	// Project paths are compared, not windows: a second window on the same
	// project is the same destination, and the alias spellings still match.
	std::vector<std::string> const twoWindows = { "/Users/me/projects/alpha", "/Users/me/projects/alpha" };
	OAK_ASSERT(agent_ide_routing::delivers_to_session(origin, "/Users/me/projects/alpha/src", twoWindows));
	OAK_ASSERT(agent_ide_routing::delivers_to_session("/var/folders/work/repo", "/private/var/folders/work/repo/src", { "/var/folders/work/repo" }));
}

void test_delivery_from_a_window_with_no_project ()
{
	// Nothing to compare against: only sessions we cannot place are eligible, so
	// a placed session is never told about a project it cannot be working on.
	OAK_ASSERT(agent_ide_routing::delivers_to_session("", "", kTwoProjects));
	OAK_ASSERT(agent_ide_routing::delivers_to_session("", "/Users/me/Desktop", kTwoProjects));
	OAK_ASSERT(!agent_ide_routing::delivers_to_session("", "/Users/me/projects/alpha", kTwoProjects));
}

// How many connected sessions a push reaches — the count the mate socket
// reports back, which is why zero has to be distinguishable from “sent”.
static size_t TargetCount (std::string const& origin, std::vector<std::string> const& sessionDirectories, std::vector<std::string> const& projectRoots)
{
	size_t res = 0;
	for(std::string const& cwd : sessionDirectories)
		res += agent_ide_routing::delivers_to_session(origin, cwd, projectRoots) ? 1 : 0;
	return res;
}

void test_target_counts ()
{
	std::string const origin = "/Users/me/projects/alpha";

	// One session in the origin project, one elsewhere, one unplaceable.
	OAK_ASSERT_EQ(TargetCount(origin, { "/Users/me/projects/alpha", "/Users/me/projects/beta", "/Users/me/Desktop" }, kTwoProjects), 2);

	// Only sessions known to be somewhere else: nobody is told, and the caller
	// is told that, rather than the mention landing in the wrong conversation.
	OAK_ASSERT_EQ(TargetCount(origin, { "/Users/me/projects/beta", "/Users/me/projects/beta/lib" }, kTwoProjects), 0);

	// Nothing connected at all is the same answer for the caller.
	OAK_ASSERT_EQ(TargetCount(origin, { }, kTwoProjects), 0);
}

void test_mention_origin ()
{
	// The mentioning process’ own directory decides…
	OAK_ASSERT_EQ(agent_ide_routing::mention_origin("/Users/me/projects/alpha/src", "/Users/me/projects/beta/README", kTwoProjects), "/Users/me/projects/alpha");

	// …and only when it identifies nothing does the mentioned file decide.
	OAK_ASSERT_EQ(agent_ide_routing::mention_origin("/Users/me/Desktop", "/Users/me/projects/beta/README", kTwoProjects), "/Users/me/projects/beta");
	OAK_ASSERT_EQ(agent_ide_routing::mention_origin("", "/Users/me/projects/beta/README", kTwoProjects), "/Users/me/projects/beta");

	// Neither: the mention has no identifiable origin and AgentBridge refuses it
	// rather than broadcasting into sessions known to be elsewhere.
	OAK_ASSERT_EQ(agent_ide_routing::mention_origin("/Users/me/Desktop", "/Users/me/Desktop/notes.txt", kTwoProjects), "");
	OAK_ASSERT_EQ(agent_ide_routing::mention_origin("/Users/me/projects", "/Users/me/projects/list.txt", kTwoProjects), "");
}

void test_client_pid_from_ide_connected_params ()
{
	pid_t pid = 0;
	OAK_ASSERT(agent_ide_routing::client_pid({ { "pid", 94687 } }, &pid));
	OAK_ASSERT_EQ(pid, 94687);

	// Anything that is not a process identifier leaves the session unrouted
	// (legacy) rather than resolving some other process’ directory.
	OAK_ASSERT(!agent_ide_routing::client_pid(nlohmann::json::object(), &pid));
	OAK_ASSERT(!agent_ide_routing::client_pid({ { "pid", 0 } }, &pid));
	OAK_ASSERT(!agent_ide_routing::client_pid({ { "pid", -1 } }, &pid));
	OAK_ASSERT(!agent_ide_routing::client_pid({ { "pid", 1.5 } }, &pid));
	OAK_ASSERT(!agent_ide_routing::client_pid({ { "pid", "94687" } }, &pid));
	OAK_ASSERT(!agent_ide_routing::client_pid({ { "pid", nullptr } }, &pid));
	OAK_ASSERT(!agent_ide_routing::client_pid({ { "pid", 4294967296 } }, &pid));  // beyond pid_t
	OAK_ASSERT(!agent_ide_routing::client_pid({ { "process", 94687 } }, &pid));
	OAK_ASSERT(!agent_ide_routing::client_pid(nlohmann::json::array(), &pid));

	OAK_ASSERT_EQ(pid, 94687); // no rejection wrote through
}

// The dispatcher’s announcement handling in miniature (ClaudeIDEContextServer’s
// ide_connected branch): store the routing path the pid resolved to, then
// install the one-shot seed once. Kept next to the assertions because the
// ORDER of the two announcements is what these tests are about.
namespace
{
	struct connection_t
	{
		std::string routingPath;
		bool seeded  = false;
		size_t seeds = 0;

		void announce (std::string const& method, std::string const& resolvedDirectory)
		{
			if(!agent_ide_routing::announcement_installs_seed(method))
				return;

			routingPath = resolvedDirectory;
			if(!seeded)
			{
				seeded = true;
				++seeds;
			}
		}
	};
}

void test_only_ide_connected_installs_the_seed ()
{
	OAK_ASSERT(agent_ide_routing::announcement_installs_seed("ide_connected"));
	OAK_ASSERT(!agent_ide_routing::announcement_installs_seed("notifications/initialized"));
	OAK_ASSERT(!agent_ide_routing::announcement_installs_seed("notifications/cancelled"));
	OAK_ASSERT(!agent_ide_routing::announcement_installs_seed("initialize"));
}

void test_startup_seeds_once_in_either_order ()
{
	// initialized first, then the identity — the order that used to seed from
	// the frontmost window before the pid was known.
	connection_t first;
	first.announce("notifications/initialized", "");
	OAK_ASSERT_EQ(first.seeds, 0);
	first.announce("ide_connected", "/Users/me/projects/alpha");
	OAK_ASSERT_EQ(first.seeds, 1);
	OAK_ASSERT_EQ(first.routingPath, "/Users/me/projects/alpha");

	// …and the reverse order, which must not seed twice.
	connection_t second;
	second.announce("ide_connected", "/Users/me/projects/alpha");
	second.announce("notifications/initialized", "");
	OAK_ASSERT_EQ(second.seeds, 1);
	OAK_ASSERT_EQ(second.routingPath, "/Users/me/projects/alpha");
}

void test_startup_without_a_usable_identity ()
{
	// A client that only ever announces initialized gets no seed at all: the
	// alternative is guessing that its identity will never arrive, and guessing
	// wrong sends another project’s file as its opening context.
	connection_t initializedOnly;
	initializedOnly.announce("notifications/initialized", "");
	OAK_ASSERT_EQ(initializedOnly.seeds, 0);
	OAK_ASSERT_EQ(initializedOnly.routingPath, "");

	// An ide_connected whose pid resolves to nothing still seeds — explicitly
	// unrouted, which is the legacy frontmost-window answer.
	connection_t unresolvedPid;
	unresolvedPid.announce("ide_connected", "");
	OAK_ASSERT_EQ(unresolvedPid.seeds, 1);
	OAK_ASSERT_EQ(unresolvedPid.routingPath, "");
}

// AgentBridgeWorkspace’s selection history in miniature (its
// ‘latestSelectionForRoutingPath:’ and the debounced record that feeds it):
// the app-wide last non-empty selection plus one per normalized project root.
// Modelled here for the same reason as the dispatcher above — the rule is what
// getLatestSelection can hand a session, and the AppKit machinery that
// produces the selections has no say in it.
namespace
{
	struct selection_history_t
	{
		std::string appWide;
		std::map<std::string, std::string> byProject;

		void record (std::string const& originProject, std::string const& selection)
		{
			appWide = selection;
			if(!originProject.empty())
				byProject[agent_routing_path::normalize(originProject)] = selection;
		}

		// checkWorkspaceFolders’ prune: keep only the projects that are open.
		void prune (std::vector<std::string> const& projectRoots)
		{
			std::set<std::string> open;
			for(std::string const& root : projectRoots)
			{
				if(!root.empty())
					open.insert(agent_routing_path::normalize(root));
			}

			for(auto it = byProject.begin(); it != byProject.end(); )
				it = open.find(it->first) == open.end() ? byProject.erase(it) : std::next(it);
		}

		std::string latest (std::string const& routingPath, std::vector<std::string> const& projectRoots) const
		{
			std::string const root = agent_ide_routing::matching_project_root(routingPath, projectRoots);
			if(root.empty())
				return appWide;

			auto it = byProject.find(root);
			return it == byProject.end() ? std::string() : it->second;
		}
	};
}

void test_latest_selection_never_crosses_projects ()
{
	// beta was selected last, so the app-wide value is beta’s — and that is
	// what a session in alpha was handed: the leak, by way of a tool call
	// rather than a push.
	selection_history_t history;
	history.record("/Users/me/projects/alpha", "alpha selection");
	history.record("/Users/me/projects/beta", "beta selection");

	OAK_ASSERT_EQ(history.latest("/Users/me/projects/alpha", kTwoProjects), "alpha selection");
	OAK_ASSERT_EQ(history.latest("/Users/me/projects/alpha/src/main.cc", kTwoProjects), "alpha selection");
	OAK_ASSERT_EQ(history.latest("/Users/me/projects/beta/lib", kTwoProjects), "beta selection");
}

void test_latest_selection_without_a_history_of_its_own ()
{
	// A placed session whose project has nothing recorded gets nothing, not
	// the other project’s text; getLatestSelection then falls back to this
	// session’s own current selection, which is routed already.
	selection_history_t onlyBeta;
	onlyBeta.record("/Users/me/projects/beta", "beta selection");
	OAK_ASSERT_EQ(onlyBeta.latest("/Users/me/projects/alpha", kTwoProjects), "");

	// Nothing recorded anywhere: unplaceable callers have nothing to fall back
	// to either.
	selection_history_t empty;
	OAK_ASSERT_EQ(empty.latest("/Users/me/projects/alpha", kTwoProjects), "");
	OAK_ASSERT_EQ(empty.latest("", kTwoProjects), "");
}

void test_latest_selection_for_unplaceable_callers ()
{
	selection_history_t history;
	history.record("/Users/me/projects/alpha", "alpha selection");
	history.record("/Users/me/projects/beta", "beta selection");

	// No routing path, outside every project, and a parent of both: the
	// app-wide value, which is the answer every caller used to get.
	OAK_ASSERT_EQ(history.latest("", kTwoProjects), "beta selection");
	OAK_ASSERT_EQ(history.latest("/Users/me/Desktop", kTwoProjects), "beta selection");
	OAK_ASSERT_EQ(history.latest("/Users/me/projects", kTwoProjects), "beta selection");

	// A session whose project window has since closed is unplaceable too.
	OAK_ASSERT_EQ(history.latest("/Users/me/projects/alpha", { "/Users/me/projects/beta" }), "beta selection");
}

void test_latest_selection_from_a_window_with_no_project ()
{
	// A window with no project has no per-project entry to update, so its
	// selection reaches only the callers the app-wide value answers — the same
	// sessions an origin-less push reaches (delivers_to_session above).
	selection_history_t history;
	history.record("/Users/me/projects/alpha", "alpha selection");
	history.record("", "untitled selection");

	OAK_ASSERT_EQ(history.latest("", kTwoProjects), "untitled selection");
	OAK_ASSERT_EQ(history.latest("/Users/me/Desktop", kTwoProjects), "untitled selection");
	OAK_ASSERT_EQ(history.latest("/Users/me/projects/alpha", kTwoProjects), "alpha selection");
	OAK_ASSERT_EQ(history.latest("/Users/me/projects/beta", kTwoProjects), "");
}

void test_latest_selection_across_macos_path_aliases ()
{
	// Recorded under the window’s spelling, asked for under the kernel’s: both
	// sides normalize, or the entry is written where no lookup will find it.
	selection_history_t history;
	history.record("/var/folders/work/repo", "repo selection");
	OAK_ASSERT_EQ(history.latest("/private/var/folders/work/repo/src", { "/var/folders/work/repo" }), "repo selection");
}

void test_latest_selection_dropped_when_its_project_closes ()
{
	// Selection bodies are stored whole, so keeping one per project ever opened
	// is unbounded growth for an answer nobody can ask for: a closed project
	// matches no routing path.
	selection_history_t history;
	history.record("/Users/me/projects/alpha", "alpha selection");
	history.record("/Users/me/projects/beta", "beta selection");

	std::vector<std::string> const onlyBeta = { "/Users/me/projects/beta" };
	history.prune(onlyBeta);
	OAK_ASSERT_EQ(history.byProject.size(), 1);

	// Still open, still answered — closing one project does not touch another’s.
	OAK_ASSERT_EQ(history.latest("/Users/me/projects/beta/lib", onlyBeta), "beta selection");

	// While alpha is closed a session there is unplaceable, as it always was,
	// and reopening it finds nothing of its own: getLatestSelection falls
	// through to that session’s current selection, which is routed already.
	OAK_ASSERT_EQ(history.latest("/Users/me/projects/alpha", onlyBeta), "beta selection");
	OAK_ASSERT_EQ(history.latest("/Users/me/projects/alpha", kTwoProjects), "");

	// The app-wide value is not per-project and is not pruned: unplaceable
	// sessions keep hearing the last selection made anywhere.
	OAK_ASSERT_EQ(history.latest("/Users/me/Desktop", kTwoProjects), "beta selection");
}

void test_latest_selection_prune_across_macos_path_aliases ()
{
	// Recorded under one spelling and open under the other, so an unnormalized
	// prune would throw away a live project’s selection.
	selection_history_t history;
	history.record("/var/folders/work/repo", "repo selection");
	history.prune({ "/private/var/folders/work/repo" });
	OAK_ASSERT_EQ(history.latest("/var/folders/work/repo/src", { "/var/folders/work/repo" }), "repo selection");
}
