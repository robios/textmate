#import "TerminalEnvironment.h"
#import <AgentBridge/AgentBridge.h>
#import <AgentBridge/AgentSetup.h>
#import <io/path.h>
#import <ns/ns.h>
#import <text/tokenize.h>

std::map<std::string, std::string> TerminalEnvironmentByAddingExtras (std::map<std::string, std::string> environment)
{
	auto mate = environment.find("TM_MATE");
	if(mate != environment.end())
	{
		std::string const dir = path::parent(mate->second);
		if(dir != NULL_STR && !dir.empty())
		{
			auto path = environment.find("PATH");
			if(path == environment.end() || path->second.empty())
			{
				environment["PATH"] = dir;
			}
			else
			{
				bool present = false;
				for(auto const& component : text::tokenize(path->second.begin(), path->second.end(), ':'))
					present = present || component == dir;

				if(!present)
					path->second += ":" + dir;
			}
		}
	}

	// A CLI launched inside the pane auto-connects to the app-global Claude
	// IDE-context server through these (external terminals discover it through
	// the lock file instead). The port only exists while the bridge runs, which
	// is why this is computed per spawn rather than stored.
	if(NSUInteger claudeIDEContextPort = [AgentBridge claudeIDEContextServerPort])
	{
		environment.emplace("CLAUDE_CODE_SSE_PORT", std::to_string(claudeIDEContextPort));
		environment.emplace("ENABLE_IDE_INTEGRATION", "true");
	}

	// The whole third-party-agent contract: a harness that can register an MCP
	// server points it at $TM_AGENT_BRIDGE and reaches TextMate’s editor
	// context. A window already contributes this through its own variables, so
	// the insertion that matters is the application-level one — that
	// environment is assembled before there is a window to pass through.
	if(NSString* agentBridge = [AgentSetup commandLineToolPath])
		environment.emplace("TM_AGENT_BRIDGE", to_s(agentBridge));

	return environment;
}
