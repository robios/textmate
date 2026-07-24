#include "agent_cli.h"

#include <cstdio>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <sysexits.h>
#include <unistd.h>

// tm_agent talks to the agent bridge inside a running TextMate over the mate
// socket (the UNIX domain socket also used by the ‘mate’ CLI, served by
// RMateServer on the app’s main queue). It is protocol-agnostic towards the
// agent: TextMate forwards ‘mention’ as an ‘at_mentioned’ notification to
// whatever agent CLI is connected to the bridge.

static char const* const AppVersion = TEXTMATE_VERSION_STRING;

static char const* socket_path ()
{
	static std::string const str = "/tmp/textmate-" + std::to_string(getuid()) + ".sock";
	return str.c_str();
}

static void usage (FILE* io)
{
	fprintf(io,
		"%1$s %2$s (" __DATE__ ")\n"
		"Usage: %1$s mention --file <path> [--line-start <n>] [--line-end <n>]\n"
		"       %1$s status\n"
		"\n"
		"Talks to the agent bridge in a running TextMate.\n"
		"\n"
		"Subcommands:\n"
		" mention   Push a file reference (at_mentioned) into the agent CLI\n"
		"           connected to TextMate. Line numbers are 0-based; omitting\n"
		"           them references the start of the file, --line-start without\n"
		"           --line-end references a single line.\n"
		" status    Print bridge state: running/stopped, port, and number of\n"
		"           connected agent clients. Exits 0 when the bridge is\n"
		"           running, 2 when it is stopped.\n"
		"\n"
		"Options:\n"
		" -h, --help     Show this information.\n"
		" -v, --version  Print version information.\n"
		"\n"
		"Exit codes: 0 success, 1 request rejected by TextMate, 2 bridge\n"
		"stopped (status), %3$d usage error, %4$d TextMate not running.\n",
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

	auto pathArg = request.arguments.find("path");
	if(pathArg != request.arguments.end())
		pathArg->second = absolute_path(pathArg->second);

	// Connect to the running app — deliberately without launching it: a
	// mention only makes sense against a live editor session.
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	struct sockaddr_un addr = { 0, AF_UNIX };
	strcpy(addr.sun_path, socket_path());
	addr.sun_len = SUN_LEN(&addr);

	if(fd == -1 || connect(fd, (sockaddr*)&addr, sizeof(addr)) == -1)
	{
		fprintf(stderr, "%s: TextMate does not appear to be running (no socket at %s)\n", getprogname(), socket_path());
		if(fd != -1)
			close(fd);
		return EX_UNAVAILABLE;
	}

	// Read the server’s welcome line before sending our request.
	char buf[1024];
	std::string received;
	while(received.find('\n') == std::string::npos)
	{
		ssize_t len = read(fd, buf, sizeof(buf));
		if(len <= 0)
		{
			fprintf(stderr, "%s: no greeting from TextMate\n", getprogname());
			close(fd);
			return EX_IOERR;
		}
		received.insert(received.end(), buf, buf + len);
	}
	received.erase(0, received.find('\n') + 1);

	std::string const frame = agent_cli::frame_request(request);
	if(write(fd, frame.data(), frame.size()) != (ssize_t)frame.size())
	{
		perror("write");
		close(fd);
		return EX_IOERR;
	}

	while(ssize_t len = read(fd, buf, sizeof(buf)))
	{
		if(len == -1)
		{
			perror("read");
			close(fd);
			return EX_IOERR;
		}
		received.insert(received.end(), buf, buf + len);
	}
	close(fd);

	auto response = agent_cli::parse_response(received);
	auto value = [&response](char const* key) -> std::string {
		auto it = response.find(key);
		return it != response.end() ? it->second : "";
	};

	if(value("status") != "ok")
	{
		std::string message = value("message");
		if(message.empty())
			message = "TextMate did not answer the request — is this TextMate build agent-bridge-enabled?";
		fprintf(stderr, "%s: %s\n", getprogname(), message.c_str());
		return 1;
	}

	if(request.command == "agent-status")
	{
		bool const running = value("running") == "yes";
		fprintf(stdout, "bridge: %s\n", running ? "running" : "stopped");
		fprintf(stdout, "port: %s\n", running ? value("port").c_str() : "0");
		fprintf(stdout, "clients: %s\n", value("clients").empty() ? "0" : value("clients").c_str());
		return running ? EX_OK : 2;
	}

	return EX_OK;
}
