#import "TerminalTargetStub.h"
#import <command/runner.h>
#import <io/path.h>
#import <ns/ns.h>

// runLocation:terminal ends the command's life in TextMate at the hand-off:
// nothing is forked, nothing is captured, and there is no later moment at which
// an exit status could arrive. What is verifiable without a window is the shape
// of that hand-off — what the terminal is given, and that the keys the mode
// ignores really do nothing on the way there.

struct outcome_t
{
	TerminalTargetStub* target;
	BOOL normalExit;
	NSInteger terminationCount;
	NSInteger notificationCount;
};

static bundle_command_t terminal_command (std::string const& body = "#!/bin/bash\ntrue\n", std::string const& name = "Run Dev Server!")
{
	bundle_command_t res;
	res.name         = name;
	res.command      = body;
	res.run_location = run_location::terminal;
	return res;
}

static outcome_t run (bundle_command_t const& command, std::map<std::string, std::string> const& variables, BOOL accept = YES)
{
	outcome_t res = { [TerminalTargetStub new], NO, 0, 0 };
	res.target.accept = accept;

	OakCommand* oakCommand = [[OakCommand alloc] initWithBundleCommand:command];
	oakCommand.firstResponder = res.target;

	__block outcome_t* out = &res;
	oakCommand.terminationHandler = ^(OakCommand* cmd, BOOL normalExit){
		out->normalExit = normalExit;
		++out->terminationCount;
	};

	id observer = [NSNotificationCenter.defaultCenter addObserverForName:OakCommandDidTerminateNotification object:oakCommand queue:nil usingBlock:^(NSNotification*){
		++out->notificationCount;
	}];

	[oakCommand executeWithInput:nil variables:variables outputHandler:nil];
	[NSNotificationCenter.defaultCenter removeObserver:observer];

	return res;
}

// ================================================================

void test_terminal_command_is_handed_off_once ()
{
	outcome_t res = run(terminal_command(), {
		{ "TM_DIRECTORY", "/usr/lib" },
		{ "MY_MARKER",    "present"  },
	});

	OAK_ASSERT_EQ(res.target.runCount, 1);
	OAK_ASSERT_EQ(res.terminationCount, 1);
	OAK_ASSERT_EQ(res.notificationCount, 1);
	OAK_ASSERT_EQ(res.normalExit, YES);
	OAK_ASSERT_EQ(to_s(res.target.directory), "/usr/lib");
	OAK_ASSERT_EQ(res.target.environment["MY_MARKER"], "present");
}

// Preparation happens once, and its result is what reaches the session — the
// hand-off neither repeats it nor layers anything on top. (That it also happens
// before requiredCommands is not observable here: a synthetic command has no
// bundle item to carry requirements.)
void test_environment_is_prepared_before_hand_off ()
{
	outcome_t res = run(terminal_command(), { });
	OAK_ASSERT_EQ(res.target.prepareCount, 1);
	OAK_ASSERT_EQ(res.target.environment["PREPARED"], "yes");
}

void test_script_is_written_readably_and_executably ()
{
	outcome_t res = run(terminal_command("#!/bin/bash\necho marker-a\n", "Run Dev Server!"), { });

	std::string const scriptPath = to_s(res.target.scriptPath);
	OAK_ASSERT_EQ(path::name(scriptPath).substr(0, std::string("Run_Dev_Server-").size()), "Run_Dev_Server-");
	OAK_ASSERT(path::is_executable(scriptPath));
	OAK_ASSERT_NE(path::content(scriptPath).find("marker-a"), std::string::npos);
}

// The cwd here is a prompt the user keeps, not the invisible scratch space an
// in-process command gets, so it falls back to the real home — and not to the
// command's own HOME, which a bundle is free to set.
void test_working_directory_falls_back_to_the_real_home ()
{
	std::string const home = to_s(NSHomeDirectory());

	OAK_ASSERT_EQ(to_s(run(terminal_command(), { { "HOME", "/nonexistent/bundle/home" } }).target.directory), home);
	OAK_ASSERT_EQ(to_s(run(terminal_command(), { { "TM_DIRECTORY", "/nonexistent/project" } }).target.directory), home);
	OAK_ASSERT_EQ(to_s(run(terminal_command(), { { "TM_PROJECT_DIRECTORY", "/usr/share" } }).target.directory), "/usr/share");
}

// “Ignored” has to mean the setting never acts, not that its result is
// discarded: reaching the output-reuse handling could stop another command's
// running HTML view on the way past.
void test_ignored_output_and_input_keys_do_not_divert_the_hand_off ()
{
	bundle_command_t command = terminal_command();
	command.output        = output::new_window;
	command.output_format = output_format::html;
	command.output_reuse  = output_reuse::abort_and_reuse_busy;
	command.input         = input::entire_document;
	command.input_format  = input_format::xml;
	command.auto_refresh  = auto_refresh::on_document_save;

	outcome_t res = run(command, { });
	OAK_ASSERT_EQ(res.target.runCount, 1);
	OAK_ASSERT_EQ(res.terminationCount, 1);
	OAK_ASSERT_EQ(res.normalExit, YES);
}

// Defensive path: with the application-level route creating a window, no
// ordinary context refuses.
void test_refused_hand_off_reports_failure_once ()
{
	outcome_t res = run(terminal_command(), { }, NO);
	OAK_ASSERT_EQ(res.target.runCount, 1);
	OAK_ASSERT_EQ(res.target.errorCount, 1);
	OAK_ASSERT_EQ(res.terminationCount, 1);
	OAK_ASSERT_EQ(res.notificationCount, 1);
	OAK_ASSERT_EQ(res.normalExit, NO);
}
