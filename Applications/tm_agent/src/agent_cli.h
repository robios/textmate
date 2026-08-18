#ifndef AGENT_CLI_H_QP47XN2M
#define AGENT_CLI_H_QP47XN2M

#include <cstdlib>
#include <map>
#include <string>
#include <vector>

// Shared between the tm_agent CLI and the AgentBridge unit tests
// (Frameworks/AgentBridge/tests/t_agent_cli.mm): argument parsing plus the
// wire framing used to talk to the app over the mate socket. Pure functions
// over std types — no I/O, no Objective-C.
namespace agent_cli
{
	struct request_t
	{
		std::string command; // "agent-mention" or "agent-status"
		std::map<std::string, std::string> arguments;
	};

	inline bool parse_line_number (std::string const& value, long* out)
	{
		if(value.empty())
			return false;

		char* end = nullptr;
		long res = strtol(value.c_str(), &end, 10);
		if(end == value.c_str() || *end != '\0' || res < 0)
			return false;

		*out = res;
		return true;
	}

	// ‘mcp’ is handled in-process rather than sent: it is a long-lived MCP
	// server on stdin/stdout that makes one agent-tool request per tool call.
	// It goes through parse_arguments all the same, so every subcommand’s
	// argument checking stays in one tested place.
	constexpr char const* McpCommand = "agent-mcp";

	// Parse ‘tm_agent <subcommand> …’ (argv[0] already stripped):
	//   mention --file <path> [--line-start <n>] [--line-end <n>]
	//   status
	//   mcp
	// Line numbers are 0-based. --line-start without --line-end references a
	// single line; omitting both references the start of the file (0-0). On
	// success fills *request and returns true, otherwise *error explains why.
	inline bool parse_arguments (std::vector<std::string> const& args, request_t* request, std::string* error)
	{
		auto fail = [&error](std::string const& message){
			if(error)
				*error = message;
			return false;
		};

		if(args.empty())
			return fail("no subcommand given (expected ‘mention’, ‘status’, or ‘mcp’)");

		std::string const& subcommand = args.front();
		if(subcommand == "status")
		{
			if(args.size() > 1)
				return fail("status takes no arguments");
			request->command = "agent-status";
			return true;
		}

		if(subcommand == "mcp")
		{
			if(args.size() > 1)
				return fail("mcp takes no arguments");
			request->command = McpCommand;
			return true;
		}

		if(subcommand != "mention")
			return fail("unknown subcommand ‘" + subcommand + "’ (expected ‘mention’, ‘status’, or ‘mcp’)");

		std::string file;
		long lineStart = -1, lineEnd = -1;

		for(size_t i = 1; i < args.size(); ++i)
		{
			std::string const& arg = args[i];
			bool const hasValue = i + 1 < args.size();

			if(arg == "--file" || arg == "-f")
			{
				if(!hasValue)
					return fail("--file requires a path");
				file = args[++i];
			}
			else if(arg == "--line-start")
			{
				if(!hasValue || !parse_line_number(args[++i], &lineStart))
					return fail("--line-start requires a non-negative integer (0-based)");
			}
			else if(arg == "--line-end")
			{
				if(!hasValue || !parse_line_number(args[++i], &lineEnd))
					return fail("--line-end requires a non-negative integer (0-based)");
			}
			else
			{
				return fail("unknown option ‘" + arg + "’");
			}
		}

		if(file.empty())
			return fail("mention requires --file <path>");
		if(lineStart == -1 && lineEnd != -1)
			return fail("--line-end requires --line-start");
		if(lineStart != -1 && lineEnd == -1)
			lineEnd = lineStart;
		if(lineStart == -1)
			lineStart = lineEnd = 0;
		if(lineEnd < lineStart)
			return fail("--line-end must not be less than --line-start");

		request->command = "agent-mention";
		request->arguments["path"]       = file;
		request->arguments["line-start"] = std::to_string(lineStart);
		request->arguments["line-end"]   = std::to_string(lineEnd);
		return true;
	}

	// The directory a request was made from, which is what tells the app which
	// project it belongs to — a mention needs it for the same reason a tool call
	// does, so it travels under the same key. Empty is dropped rather than sent
	// as an empty value: the framing would drop it anyway, and a missing key
	// reads as “not supplied” on the far side.
	inline void set_request_cwd (request_t* request, std::string const& cwd)
	{
		if(!cwd.empty())
			request->arguments["cwd"] = cwd;
	}

	// The directory a mention counts as being made from, given the value of
	// TM_PROJECT_DIRECTORY and this process’ own working directory.
	//
	// TextMate sets that variable for bundle commands and exports it into the
	// integrated terminal’s shell, where it names the window the mention was
	// started from — the origin routing wants. The working directory does not:
	// a bundle command runs in the document’s directory, which may sit in
	// another project or in none, so the same mention would be delivered
	// elsewhere or refused outright. A shell outside TextMate has no such
	// variable, and one carrying an unusable value (empty, or relative, which
	// no project root can be matched against) is no better than none.
	inline std::string mention_cwd (char const* projectDirectory, std::string const& cwd)
	{
		std::string const project = projectDirectory ? projectDirectory : std::string();
		return !project.empty() && project.front() == '/' ? project : cwd;
	}

	// The request the MCP shim makes per tool call. ‘arguments’ is the tool’s
	// argument object already serialized as JSON — one string on one wire line,
	// since the framing below escapes newlines — and ‘cwd’ is the directory the
	// shim was started in, which is what routes the query to the window whose
	// project contains it. Both are omitted when empty (see set_request_cwd).
	inline request_t tool_request (std::string const& name, std::string const& arguments, std::string const& cwd)
	{
		request_t res;
		res.command = "agent-tool";
		res.arguments["name"] = name;
		if(!arguments.empty())
			res.arguments["arguments"] = arguments;
		set_request_cwd(&res, cwd);
		return res;
	}

	// Same value escaping as mate’s write_key_pair (RMateServer unescapes).
	inline std::string escape_value (std::string const& value)
	{
		std::string escaped;
		for(char const ch : value)
		{
			if(ch == '\\')
				escaped += "\\\\";
			else if(ch == '\n')
				escaped += "\\n";
			else
				escaped += ch;
		}
		return escaped;
	}

	// Frame a request for the mate socket: command line, ‘key: value’
	// argument lines, blank line to end the record, ‘.’ to end the session.
	inline std::string frame_request (request_t const& request)
	{
		std::string res = request.command + "\r\n";
		for(auto const& pair : request.arguments)
			res += pair.first + ": " + escape_value(pair.second) + "\r\n";
		res += "\r\n.\r\n";
		return res;
	}

	// Parse the app’s response: ‘key: value’ lines (CRLF or LF). Lines
	// without ‘: ’ — e.g. the server’s ‘220 …’ welcome — are ignored.
	inline std::map<std::string, std::string> parse_response (std::string const& data)
	{
		std::map<std::string, std::string> res;
		size_t from = 0;
		while(from < data.size())
		{
			size_t to = data.find('\n', from);
			std::string line = data.substr(from, to == std::string::npos ? std::string::npos : to - from);
			from = to == std::string::npos ? data.size() : to + 1;

			if(!line.empty() && line.back() == '\r')
				line.pop_back();

			size_t n = line.find(": ");
			if(n == std::string::npos)
				continue;

			std::string value;
			bool unescapeNext = false;
			for(char const ch : line.substr(n + 2))
			{
				if(unescapeNext)
				{
					value += ch == 'n' ? '\n' : ch;
					unescapeNext = false;
				}
				else if(ch == '\\')
				{
					unescapeNext = true;
				}
				else
				{
					value += ch;
				}
			}
			res[line.substr(0, n)] = value;
		}
		return res;
	}

} /* agent_cli */

#endif /* AGENT_CLI_H_QP47XN2M */
