#include "agent_cli.h"
#include "mate_client.h"
#include "mcp_shim.h"

#include <climits>
#include <csignal>
#include <cstdio>
#include <sysexits.h>
#include <unistd.h>

// tm_agent talks to AgentBridge inside a running TextMate over the mate socket
// (the UNIX domain socket also used by the ‘mate’ CLI, served by RMateServer on
// the app’s main queue). ‘mention’ and ‘status’ target Claude Code's native
// IDE-context route; ‘mcp’ is the provider-neutral stdio MCP route.

static char const* const AppVersion = TEXTMATE_VERSION_STRING;

static void usage (FILE* io)
{
	fprintf(io,
		"%1$s %2$s (" __DATE__ ")\n"
		"Usage: %1$s mention --file <path> [--line-start <n>] [--line-end <n>]\n"
		"       %1$s status\n"
		"       %1$s mcp\n"
		"\n"
		"Connects agent CLIs to editor context from a running TextMate.\n"
		"\n"
		"Subcommands:\n"
		" mention   Push a file reference (at_mentioned) into Claude Code\n"
		"           connected to TextMate. Line numbers are 0-based; omitting\n"
		"           them references the start of the file, --line-start without\n"
		"           --line-end references a single line.\n"
		" status    Print Claude IDE-context state, port, and connected Claude\n"
		"           client count. Exits 0 when active, 2 when stopped.\n"
		" mcp       Serve the Model Context Protocol on stdin/stdout, exposing\n"
		"           TextMate’s editor context (current selection, open files,\n"
		"           project folders, diagnostics) to any agent CLI configured\n"
		"           with it as an MCP server. Queries are answered by the\n"
		"           window whose project contains this process’ working\n"
		"           directory. Not meant to be run by hand.\n"
		"\n"
		"Options:\n"
		" -h, --help     Show this information.\n"
		" -v, --version  Print version information.\n"
		"\n"
		"Exit codes: 0 success, 1 request rejected by TextMate, 2 Claude IDE\n"
		"context stopped (status), %3$d usage error, %4$d TextMate not running.\n",
		getprogname(), AppVersion, EX_USAGE, EX_UNAVAILABLE
	);
}

static std::string absolute_path (std::string const& path)
{
	if(!path.empty() && path.front() == '/')
		return path;

	char cwd[PATH_MAX];
	if(getcwd(cwd, sizeof(cwd)))
		return std::string(cwd) + "/" + path;
	return path;
}

int main (int argc, char const* argv[])
{
	// “TextMate is not running” reaches us two ways, and only one of them is an
	// errno. If the app goes away between the greeting and the write — a quit
	// or a crash during a tool call — the write is answered with SIGPIPE, whose
	// default action kills us. For the shim that is the worst possible failure:
	// it exists so the agent CLI keeps a healthy server across the app coming
	// and going, and instead the server vanishes mid-session, which is the
	// outcome the offline handling was written to prevent. Ignoring the signal
	// routes it into the EPIPE path the code already has, and the agent reads a
	// tool error instead of losing its MCP server.
	signal(SIGPIPE, SIG_IGN);

	std::vector<std::string> args(argv + 1, argv + argc);

	for(auto const& arg : args)
	{
		if(arg == "-h" || arg == "--help")
			return usage(stdout), EX_OK;
		if(arg == "-v" || arg == "--version")
			return fprintf(stdout, "%s %s (" __DATE__ ")\n", getprogname(), AppVersion), EX_OK;
	}

	agent_cli::request_t request;
	std::string parseError;
	if(!agent_cli::parse_arguments(args, &request, &parseError))
	{
		fprintf(stderr, "%s: %s\n", getprogname(), parseError.c_str());
		fprintf(stderr, "Try ‘%s --help’ for more information.\n", getprogname());
		return EX_USAGE;
	}

	// ‘mcp’ is not a one-shot request but a server that makes its own, one per
	// tool call, for as long as the agent CLI keeps it alive.
	if(request.command == agent_cli::McpCommand)
		return mcp_shim::run(AppVersion);

	auto pathArg = request.arguments.find("path");
	if(pathArg != request.arguments.end())
		pathArg->second = absolute_path(pathArg->second);

	// Connect to the running app — deliberately without launching it: a
	// mention only makes sense against a live editor session.
	std::map<std::string, std::string> response;
	std::string error;
	if(!mate_client::send(request, &response, &error))
	{
		fprintf(stderr, "%s: %s\n", getprogname(), error.c_str());
		return EX_UNAVAILABLE;
	}

	auto value = [&response](char const* key) -> std::string {
		auto it = response.find(key);
		return it != response.end() ? it->second : "";
	};

	if(value("status") != "ok")
	{
		std::string message = value("message");
		if(message.empty())
			message = "TextMate did not answer the request — is editor context sharing available in this build?";
		fprintf(stderr, "%s: %s\n", getprogname(), message.c_str());
		return 1;
	}

	if(request.command == "agent-status")
	{
		bool const running = value("running") == "yes";
		fprintf(stdout, "claude-ide-context: %s\n", running ? "running" : "stopped");
		fprintf(stdout, "port: %s\n", running ? value("port").c_str() : "0");
		fprintf(stdout, "clients: %s\n", value("clients").empty() ? "0" : value("clients").c_str());
		return running ? EX_OK : 2;
	}

	return EX_OK;
}
