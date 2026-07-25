#import "../src/agent_quote.h"

// The Codex launch line puts a filesystem path inside a TOML string inside a
// shell word. §6.2 calls out the case that matters — a tm_agent path
// containing spaces — but a quote or a backslash in a path is the same bug
// with a sharper edge, so both escapes are pinned here.

void test_toml_quoting ()
{
	OAK_ASSERT_EQ(agent_quote::toml("/usr/local/bin/tm_agent"), "\"/usr/local/bin/tm_agent\"");
	OAK_ASSERT_EQ(agent_quote::toml("/Users/me/My Apps/TextMate.app/tm_agent"), "\"/Users/me/My Apps/TextMate.app/tm_agent\"");
	OAK_ASSERT_EQ(agent_quote::toml("/tmp/back\\slash"), "\"/tmp/back\\\\slash\"");
	OAK_ASSERT_EQ(agent_quote::toml("/tmp/say \"hi\""), "\"/tmp/say \\\"hi\\\"\"");
}

void test_shell_quoting ()
{
	// A plain word is left alone: the line is typed into a terminal the user
	// reads, and needless quoting only makes it harder to follow.
	OAK_ASSERT_EQ(agent_quote::shell("codex"), "codex");
	OAK_ASSERT_EQ(agent_quote::shell("/usr/local/bin/codex"), "/usr/local/bin/codex");

	OAK_ASSERT_EQ(agent_quote::shell(""), "''");
	OAK_ASSERT_EQ(agent_quote::shell("/Users/me/My Apps/codex"), "'/Users/me/My Apps/codex'");
	OAK_ASSERT_EQ(agent_quote::shell("mcp_servers.textmate.args=[\"mcp\"]"), "'mcp_servers.textmate.args=[\"mcp\"]'");

	// The one character single quotes cannot carry: leave the run, escape it,
	// come back in.
	OAK_ASSERT_EQ(agent_quote::shell("/Users/me/Ben's Apps/codex"), "'/Users/me/Ben'\\''s Apps/codex'");

	// Nothing a path can contain may end the quoted run early.
	OAK_ASSERT_EQ(agent_quote::shell("a; rm -rf /"), "'a; rm -rf /'");
	OAK_ASSERT_EQ(agent_quote::shell("$(whoami)"), "'$(whoami)'");
	OAK_ASSERT_EQ(agent_quote::shell("a`b`"), "'a`b`'");
}

void test_codex_override_round_trip ()
{
	// What the launcher builds, for a path with a space in it: the shell hands
	// Codex one argument, whose TOML parses back to the original path.
	std::string const path = "/Users/me/My Apps/TextMate.app/Contents/MacOS/tm_agent";
	std::string const value = agent_quote::shell("mcp_servers.textmate.command=" + agent_quote::toml(path));
	OAK_ASSERT_EQ(value, "'mcp_servers.textmate.command=\"/Users/me/My Apps/TextMate.app/Contents/MacOS/tm_agent\"'");
}

void test_codex_private_tmpdir_assignment ()
{
	OAK_ASSERT_EQ(agent_quote::environment("TMPDIR", "/private/tmp/tm-codex-Ab12Cd"), "TMPDIR=/private/tmp/tm-codex-Ab12Cd");
	OAK_ASSERT_EQ(agent_quote::environment("TMPDIR", "/tmp/Ben's Codex; echo unsafe"),
		"TMPDIR='/tmp/Ben'\\''s Codex; echo unsafe'");
}
