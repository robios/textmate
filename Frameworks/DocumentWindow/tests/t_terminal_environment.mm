#import <DocumentWindow/TerminalEnvironment.h>

// The environment a runLocation:terminal command's session is spawned with is
// finalised before requiredCommands is checked against it, and the same helper
// runs on both the window and the no-window route. Two properties make that
// safe, and neither is visible from the call sites: the base always wins, and
// applying the helper twice changes nothing.

typedef std::map<std::string, std::string> env_t;

static std::string const kMate = "/Applications/TextMate.app/Contents/MacOS/mate";
static std::string const kMateDirectory = "/Applications/TextMate.app/Contents/MacOS";

void test_mate_directory_is_appended_at_lower_precedence ()
{
	env_t const res = TerminalEnvironmentByAddingExtras({ { "TM_MATE", kMate }, { "PATH", "/usr/bin:/bin" } });
	OAK_ASSERT_EQ(res.at("PATH"), "/usr/bin:/bin:" + kMateDirectory);
}

void test_mate_directory_is_not_duplicated ()
{
	std::string const path = kMateDirectory + ":/usr/bin";
	env_t const res = TerminalEnvironmentByAddingExtras({ { "TM_MATE", kMate }, { "PATH", path } });
	OAK_ASSERT_EQ(res.at("PATH"), path);
}

void test_helper_is_idempotent ()
{
	env_t const once  = TerminalEnvironmentByAddingExtras({ { "TM_MATE", kMate }, { "PATH", "/usr/bin" } });
	env_t const twice = TerminalEnvironmentByAddingExtras(once);
	OAK_ASSERT_EQ(once.size(), twice.size());
	OAK_ASSERT_EQ(once.at("PATH"), twice.at("PATH"));
}

// Dropping TM_MATE support because a command cleared PATH would be the wrong
// trade; so would leaving an empty leading component, which several shells read
// as the working directory.
void test_absent_or_empty_path_is_initialised ()
{
	OAK_ASSERT_EQ(TerminalEnvironmentByAddingExtras({ { "TM_MATE", kMate } }).at("PATH"), kMateDirectory);
	OAK_ASSERT_EQ(TerminalEnvironmentByAddingExtras({ { "TM_MATE", kMate }, { "PATH", "" } }).at("PATH"), kMateDirectory);
}

void test_without_tm_mate_nothing_is_added_to_path ()
{
	env_t const res = TerminalEnvironmentByAddingExtras({ { "PATH", "/usr/bin" } });
	OAK_ASSERT_EQ(res.at("PATH"), "/usr/bin");
}

// A bundle or .tm_properties may deliberately override or disable an
// integration value; the helper inserts, it does not overwrite.
void test_existing_integration_values_win ()
{
	env_t const res = TerminalEnvironmentByAddingExtras({
		{ "CLAUDE_CODE_SSE_PORT",   "1" },
		{ "ENABLE_IDE_INTEGRATION", "false" },
		{ "TM_AGENT_BRIDGE",        "/somewhere/else/tm_agent" },
	});
	OAK_ASSERT_EQ(res.at("CLAUDE_CODE_SSE_PORT"),   "1");
	OAK_ASSERT_EQ(res.at("ENABLE_IDE_INTEGRATION"), "false");
	OAK_ASSERT_EQ(res.at("TM_AGENT_BRIDGE"),        "/somewhere/else/tm_agent");
}

// Unlike the Claude variables this one does not depend on the bridge running,
// so a terminal command always has an editor-context path to hand an agent —
// including on the application-level route, whose environment never passes
// through a window’s variables.
void test_agent_bridge_is_added ()
{
	env_t const res = TerminalEnvironmentByAddingExtras({ });
	OAK_ASSERT(res.find("TM_AGENT_BRIDGE") != res.end());
	OAK_ASSERT(!res.at("TM_AGENT_BRIDGE").empty());
}

// Only process-global integrations belong here — which is what lets the helper
// run before the application-level route has created its window.
void test_no_document_or_project_variables_are_added ()
{
	env_t const res = TerminalEnvironmentByAddingExtras({ });
	OAK_ASSERT(res.find("TM_FILEPATH") == res.end());
	OAK_ASSERT(res.find("TM_DIRECTORY") == res.end());
	OAK_ASSERT(res.find("TM_PROJECT_DIRECTORY") == res.end());
}
