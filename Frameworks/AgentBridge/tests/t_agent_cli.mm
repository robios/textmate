#import "../../../Applications/tm_agent/src/agent_cli.h"

// Tests for the tm_agent CLI helpers: argument parsing and the mate socket
// wire framing. The header is pure C++, shared with Applications/tm_agent.

void test_parse_status ()
{
	agent_cli::request_t request;
	std::string error;
	OAK_ASSERT(agent_cli::parse_arguments({ "status" }, &request, &error));
	OAK_ASSERT_EQ(request.command, "agent-status");
	OAK_ASSERT(request.arguments.empty());

	OAK_ASSERT(!agent_cli::parse_arguments({ "status", "--extra" }, &request, &error));
}

void test_parse_mention ()
{
	agent_cli::request_t request;
	std::string error;

	OAK_ASSERT(agent_cli::parse_arguments({ "mention", "--file", "/tmp/foo.txt", "--line-start", "3", "--line-end", "7" }, &request, &error));
	OAK_ASSERT_EQ(request.command, "agent-mention");
	OAK_ASSERT_EQ(request.arguments["path"], "/tmp/foo.txt");
	OAK_ASSERT_EQ(request.arguments["line-start"], "3");
	OAK_ASSERT_EQ(request.arguments["line-end"], "7");

	// --line-start without --line-end references a single line
	OAK_ASSERT(agent_cli::parse_arguments({ "mention", "-f", "/tmp/foo.txt", "--line-start", "5" }, &request, &error));
	OAK_ASSERT_EQ(request.arguments["line-start"], "5");
	OAK_ASSERT_EQ(request.arguments["line-end"], "5");

	// no line arguments references the start of the file
	OAK_ASSERT(agent_cli::parse_arguments({ "mention", "--file", "/tmp/foo.txt" }, &request, &error));
	OAK_ASSERT_EQ(request.arguments["line-start"], "0");
	OAK_ASSERT_EQ(request.arguments["line-end"], "0");

	// --project rides beside the wire arguments rather than in them: it decides
	// the ‘cwd’ that is sent (mention_cwd), and is not itself a request key.
	OAK_ASSERT(agent_cli::parse_arguments({ "mention", "--file", "/tmp/foo.txt", "--project", "/Users/me/project" }, &request, &error));
	OAK_ASSERT_EQ(request.project, "/Users/me/project");
	OAK_ASSERT_EQ(request.arguments.count("project"), 0);

	// omitted, it is simply empty — mention_cwd then keeps the working directory
	OAK_ASSERT(agent_cli::parse_arguments({ "mention", "--file", "/tmp/foo.txt" }, &request, &error));
	OAK_ASSERT_EQ(request.project, "");
}

void test_parse_mention_errors ()
{
	agent_cli::request_t request;
	std::string error;

	OAK_ASSERT(!agent_cli::parse_arguments({ }, &request, &error));
	OAK_ASSERT(!agent_cli::parse_arguments({ "bogus" }, &request, &error));
	OAK_ASSERT(!agent_cli::parse_arguments({ "mention" }, &request, &error));                                                        // missing --file
	OAK_ASSERT(!agent_cli::parse_arguments({ "mention", "--file" }, &request, &error));                                              // missing value
	OAK_ASSERT(!agent_cli::parse_arguments({ "mention", "--file", "/a", "--line-start", "x" }, &request, &error));                   // not a number
	OAK_ASSERT(!agent_cli::parse_arguments({ "mention", "--file", "/a", "--line-start", "-1" }, &request, &error));                  // negative
	OAK_ASSERT(!agent_cli::parse_arguments({ "mention", "--file", "/a", "--line-end", "3" }, &request, &error));                     // end without start
	OAK_ASSERT(!agent_cli::parse_arguments({ "mention", "--file", "/a", "--line-start", "5", "--line-end", "2" }, &request, &error)); // end < start
	OAK_ASSERT(!agent_cli::parse_arguments({ "mention", "--file", "/a", "--bogus" }, &request, &error));                             // unknown option
	OAK_ASSERT(!agent_cli::parse_arguments({ "mention", "--file", "/a", "--project" }, &request, &error));                           // missing value
	OAK_ASSERT(!error.empty());

	// An unusable --project value is not a usage error: the caller falls back to
	// the working directory, so the mention is placed rather than refused.
	OAK_ASSERT(agent_cli::parse_arguments({ "mention", "--file", "/a", "--project", "" }, &request, &error));
	OAK_ASSERT(agent_cli::parse_arguments({ "mention", "--file", "/a", "--project", "relative/path" }, &request, &error));
}

void test_frame_request ()
{
	agent_cli::request_t request;
	request.command = "agent-mention";
	request.arguments["path"]       = "/tmp/foo.txt";
	request.arguments["line-start"] = "3";
	request.arguments["line-end"]   = "7";

	// std::map orders keys alphabetically: line-end, line-start, path
	OAK_ASSERT_EQ(agent_cli::frame_request(request), "agent-mention\r\nline-end: 7\r\nline-start: 3\r\npath: /tmp/foo.txt\r\n\r\n.\r\n");
}

void test_frame_request_escaping ()
{
	agent_cli::request_t request;
	request.command = "agent-mention";
	request.arguments["path"] = "/tmp/back\\slash\nnewline";

	OAK_ASSERT_EQ(agent_cli::frame_request(request), "agent-mention\r\npath: /tmp/back\\\\slash\\nnewline\r\n\r\n.\r\n");
}

void test_parse_response ()
{
	auto response = agent_cli::parse_response("220 host RMATE TextMate (Darwin 24)\r\nstatus: ok\r\nclients: 2\r\n");
	OAK_ASSERT_EQ(response["status"], "ok");
	OAK_ASSERT_EQ(response["clients"], "2");
	OAK_ASSERT_EQ(response.size(), 2);

	response = agent_cli::parse_response("status: error\r\nmessage: no such file: /tmp/a\\nb\r\n");
	OAK_ASSERT_EQ(response["status"], "error");
	OAK_ASSERT_EQ(response["message"], "no such file: /tmp/a\nb");

	OAK_ASSERT(agent_cli::parse_response("").empty());
	OAK_ASSERT(agent_cli::parse_response("garbage without separator\n").empty());
}

void test_parse_mcp ()
{
	agent_cli::request_t request;
	std::string error;

	// ‘mcp’ goes through the same parser as the one-shot subcommands so its
	// argument checking is not a separate path — main recognizes the sentinel
	// command and serves the protocol instead of sending anything.
	OAK_ASSERT(agent_cli::parse_arguments({ "mcp" }, &request, &error));
	OAK_ASSERT_EQ(request.command, agent_cli::McpCommand);
	OAK_ASSERT(request.arguments.empty());

	OAK_ASSERT(!agent_cli::parse_arguments({ "mcp", "--serve" }, &request, &error));
}

void test_tool_request ()
{
	agent_cli::request_t request = agent_cli::tool_request("getCurrentSelection", "{\"uri\":\"file:///tmp/a\"}", "/Users/me/project");
	OAK_ASSERT_EQ(request.command, "agent-tool");
	OAK_ASSERT_EQ(request.arguments["name"], "getCurrentSelection");
	OAK_ASSERT_EQ(request.arguments["arguments"], "{\"uri\":\"file:///tmp/a\"}");
	OAK_ASSERT_EQ(request.arguments["cwd"], "/Users/me/project");

	// The framing drops empty values, so an empty argument object or an
	// unknown cwd is simply absent rather than an empty key on the wire.
	request = agent_cli::tool_request("getOpenEditors", "", "");
	OAK_ASSERT_EQ(request.arguments.size(), 1);
	OAK_ASSERT_EQ(agent_cli::frame_request(request), "agent-tool\r\nname: getOpenEditors\r\n\r\n.\r\n");
}

void test_request_cwd ()
{
	// A mention carries the directory it was made in for the same reason a tool
	// call does: it is what tells the app which project — and therefore which
	// Claude session — the request belongs to.
	agent_cli::request_t request;
	std::string error;
	OAK_ASSERT(agent_cli::parse_arguments({ "mention", "--file", "/Users/me/project/a.txt" }, &request, &error));

	agent_cli::set_request_cwd(&request, "/Users/me/project");
	OAK_ASSERT_EQ(request.arguments["cwd"], "/Users/me/project");

	// An unknown working directory is absent rather than empty, so the app reads
	// it as “not supplied” and falls back to the mentioned path’s project.
	agent_cli::set_request_cwd(&request, "");
	OAK_ASSERT_EQ(request.arguments["cwd"], "/Users/me/project");

	agent_cli::request_t withoutCwd;
	OAK_ASSERT(agent_cli::parse_arguments({ "mention", "--file", "/Users/me/project/a.txt" }, &withoutCwd, &error));
	agent_cli::set_request_cwd(&withoutCwd, "");
	OAK_ASSERT_EQ(withoutCwd.arguments.count("cwd"), 0);
}

void test_mention_cwd_prefers_the_stated_project ()
{
	// A bundle command runs in the document’s directory, so “Send Selection to
	// Claude” on a file outside the window’s project — or inside a checkout
	// nested in it — would name the wrong project, or none. --project names the
	// window that started it.
	OAK_ASSERT_EQ(agent_cli::mention_cwd("/Users/me/project", "/Users/me/elsewhere"), "/Users/me/project");
	OAK_ASSERT_EQ(agent_cli::mention_cwd("/Users/me/project", "/Users/me/project/vendor/library"), "/Users/me/project");

	// A shell invocation states no project, and an unusable value is no better
	// than none: both keep the working directory, which is the identity the
	// WebSocket server resolves sessions by, so the two cannot disagree.
	OAK_ASSERT_EQ(agent_cli::mention_cwd("", "/Users/me/elsewhere"), "/Users/me/elsewhere");
	OAK_ASSERT_EQ(agent_cli::mention_cwd("project", "/Users/me/elsewhere"), "/Users/me/elsewhere");

	// Nothing to fall back to either: dropped by set_request_cwd, read as “not
	// supplied” by the app, which then places the mention by its file path.
	OAK_ASSERT_EQ(agent_cli::mention_cwd("", ""), "");
}
