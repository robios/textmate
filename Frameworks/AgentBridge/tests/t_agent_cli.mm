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
	OAK_ASSERT(!error.empty());
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
