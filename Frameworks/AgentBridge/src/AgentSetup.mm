#import "AgentSetup.h"
#import "AgentBridge.h"
#import "agent_quote.h"
#import <OakSystem/application.h>
#import <settings/settings.h>
#import <ns/ns.h>

static NSString* ShellQuoted (NSString* value)
{
	return [AgentSetup shellQuoted:value];
}

static NSString* TOMLQuoted (NSString* value)
{
	return to_ns(agent_quote::toml(to_s(value)));
}

@implementation AgentSetup
+ (NSString*)shellQuoted:(NSString*)value
{
	return to_ns(agent_quote::shell(to_s(value)));
}

+ (NSString*)commandLineToolPath
{
	// AgentBridge keeps this symlink current for whichever app instance
	// launched most recently, which is exactly what a configuration file wants
	// to name.
	NSString* link = to_ns(oak::application_t::support("bin/tm_agent"));
	if([NSFileManager.defaultManager isExecutableFileAtPath:link])
		return link;
	return [NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"tm_agent"].path;
}

+ (NSString*)codexExecutable
{
	std::string const command = settings_for_path().get("codexCommand", "");
	return command.empty() ? @"codex" : to_ns(command);
}

+ (NSString*)claudeExecutable
{
	std::string const command = settings_for_path().get("claudeCommand", "");
	return command.empty() ? @"claude" : to_ns(command);
}

+ (NSString*)claudeLaunchCommandLine
{
	return ShellQuoted([self claudeExecutable]);
}

+ (NSString*)codexLaunchCommandLine
{
	NSString* command = [NSString stringWithFormat:@"mcp_servers.textmate.command=%@", TOMLQuoted([self commandLineToolPath])];
	NSString* temporaryDirectory = [AgentBridge codexIDEContextTemporaryDirectory];
	// Codex discovers its fallback IDE socket below TMPDIR, so a TextMate-
	// launched Codex and its children intentionally inherit this private path.
	// The server only removes it when empty; child-created files are left for
	// macOS temp cleanup rather than deleted while the Codex session may live.
	NSString* environment = temporaryDirectory.length ? [NSString stringWithFormat:@"%@ ", to_ns(agent_quote::environment("TMPDIR", to_s(temporaryDirectory)))] : @"";
	return [NSString stringWithFormat:@"%@%@ -c %@ -c %@",
		environment,
		ShellQuoted([self codexExecutable]),
		ShellQuoted(command),
		ShellQuoted(@"mcp_servers.textmate.args=[\"mcp\"]")];
}

+ (NSString*)codexConfigurationSnippet
{
	return [NSString stringWithFormat:
		@"# ~/.codex/config.toml — lets Codex read what you are looking at in TextMate.\n"
		 "# Only needed for a Codex you start yourself; Terminal → New Codex Terminal\n"
		 "# registers the server at launch instead.\n"
		 "[mcp_servers.textmate]\n"
		 "command = %@\n"
		 "args = [\"mcp\"]\n",
		TOMLQuoted([self commandLineToolPath])];
}

+ (NSString*)agentsFileSnippet
{
	return
		@"## TextMate\n"
		 "\n"
		 "I am editing this project in TextMate, which exposes its live editor state\n"
		 "to you through the `textmate` MCP server. Prefer it over guessing:\n"
		 "\n"
		 "- Call `getCurrentSelection` whenever I refer to the current file, the\n"
		 "  selection, the cursor, or “this code”. The editor buffer may hold unsaved\n"
		 "  changes that are not on disk yet.\n"
		 "- Call `getOpenEditors` and `getWorkspaceFolders` before resolving a path I\n"
		 "  did not spell out.\n"
		 "- Call `getDiagnostics` when I mention an error or a warning, rather than\n"
		 "  asking me to paste it.\n"
		 "- Call `openFile` to put the code you are describing in front of me.\n"
		 "\n"
		 "Your CLI may namespace these — `textmate.getCurrentSelection` — so map the\n"
		 "names onto the tools you actually have.\n";
}
@end
