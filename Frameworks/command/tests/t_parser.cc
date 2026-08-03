#include <command/parser.h>

static std::string as_str (run_location::type runLocation)
{
	switch(runLocation)
	{
		case run_location::in_process: return "in_process";
		case run_location::terminal:   return "terminal";
	}
}

static bundle_command_t parse (plist::dictionary_t plist)
{
	plist["name"]    = std::string("Test Command");
	plist["command"] = std::string("#!/bin/bash\necho hello\n");
	return parse_command(plist);
}

void test_run_location_default ()
{
	OAK_ASSERT_EQ(as_str(parse({ }).run_location), as_str(run_location::in_process));
}

void test_run_location_terminal ()
{
	OAK_ASSERT_EQ(as_str(parse({ { "runLocation", std::string("terminal") } }).run_location), as_str(run_location::terminal));
}

void test_run_location_in_process ()
{
	OAK_ASSERT_EQ(as_str(parse({ { "runLocation", std::string("inProcess") } }).run_location), as_str(run_location::in_process));
}

// An unrecognized value must not become ‘terminal’ (nor anything else): a
// bundle written for a later TextMate has to stay runnable here. This holds
// because parse()’s index_of base case returns 0 — i.e. as long as in_process
// is enum value 0, which is the same implicit contract every other key relies
// on.
void test_run_location_unknown_is_in_process ()
{
	OAK_ASSERT_EQ(as_str(parse({ { "runLocation", std::string("newWindow") } }).run_location), as_str(run_location::in_process));
}

// runLocation has no TextMate 1.x equivalent, so the v1 conversion neither
// produces nor consumes it — but it must not drop it either.
void test_run_location_survives_v1_conversion ()
{
	plist::dictionary_t plist;
	plist["version"]     = int32_t(1);
	plist["output"]      = std::string("showAsTooltip");
	plist["runLocation"] = std::string("terminal");

	bundle_command_t const command = parse(convert_command_from_v1(plist));
	OAK_ASSERT_EQ(as_str(command.run_location), as_str(run_location::terminal));
	OAK_ASSERT_EQ((int32_t)command.output, (int32_t)output::tool_tip);
}
