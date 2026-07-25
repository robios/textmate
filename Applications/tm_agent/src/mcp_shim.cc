#include "mcp_shim.h"
#include "agent_cli.h"
#include "mate_client.h"

#include <climits>
#include <cstdio>
#include <iostream>
#include <unistd.h>

namespace mcp_shim
{
	// The directory the agent CLI started us in, captured once: it is what
	// routes every query to the TextMate window whose project contains it, and
	// a long-running shim must not let a later chdir (there is none, but the
	// guarantee is cheap) change which window answers.
	static std::string startup_directory ()
	{
		char cwd[PATH_MAX];
		return getcwd(cwd, sizeof(cwd)) ? std::string(cwd) : std::string();
	}

	int run (std::string const& version)
	{
		std::string const cwd = startup_directory();

		context_t context;
		context.version = version;
		context.invoke  = [&cwd](std::string const& name, nlohmann::json const& arguments) -> tool_result_t {
			// dump() must not throw on a client’s arguments; whatever the model
			// sent is echoed back to TextMate as-is.
			std::string const serialized = arguments.empty() ? std::string() : arguments.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);

			std::map<std::string, std::string> response;
			std::string error;
			if(!mate_client::send(agent_cli::tool_request(name, serialized, cwd), &response, &error))
				return { false, false, "TextMate is not running, so the editor context is unavailable: " + error };

			auto value = [&response](char const* key) -> std::string {
				auto it = response.find(key);
				return it != response.end() ? it->second : std::string();
			};

			if(value("status") != "ok")
			{
				std::string message = value("message");
				if(message.empty())
					message = "TextMate did not answer the request — is this TextMate build agent-bridge-enabled?";
				return { false, false, message };
			}

			return { true, value("tool-error") == "yes", value("result") };
		};

		// Newline-delimited JSON in, newline-delimited JSON out. Nothing else
		// may reach stdout — it is the transport; diagnostics go to stderr.
		//
		// Strictly serial: nothing is read until the line in hand is answered.
		// Every answer is either immediate or one socket round trip, so this is
		// the right simplicity — but it does set the blast radius of a tool
		// call that never returns. Such a call does not merely fail to answer;
		// it stops this loop, so `ping` goes unanswered too and a client that
		// health-checks will drop the server for the session. That is a correct
		// thing for the client to do, and it is the reason a hung call is worth
		// treating as a real risk rather than one bad answer.
		std::string line;
		while(std::getline(std::cin, line))
		{
			if(!line.empty() && line.back() == '\r')
				line.pop_back();
			if(line.empty())
				continue;

			nlohmann::json response;
			if(!handle_line(line, context, &response))
				continue;

			std::cout << response.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace) << "\n" << std::flush;
		}

		return 0;
	}

} /* mcp_shim */
