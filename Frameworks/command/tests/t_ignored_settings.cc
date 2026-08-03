#include <command/ignored_settings.h>

// What the Bundle Editor tells the author it will not honour. The subtle half
// is what must stay silent: the editor writes input, outputLocation and their
// neighbours into every command it opens, so a warning driven by key presence
// would fire on a terminal command that never left its defaults.

static plist::dictionary_t command_plist (plist::dictionary_t plist)
{
	plist["name"]        = std::string("Test Command");
	plist["command"]     = std::string("#!/bin/bash\necho hello\n");
	plist["runLocation"] = std::string("terminal");
	return plist;
}

void test_a_terminal_command_at_its_defaults_asks_for_nothing ()
{
	OAK_ASSERT_EQ(command::ignored_settings(command_plist({ }), false).size(), 0);
}

// The materialised defaults, spelled out the way the editor writes them.
void test_default_values_written_out_are_still_defaults ()
{
	auto const plist = command_plist({
		{ "input",            std::string("selection")      },
		{ "fallbackInput",    std::string("document")       },
		{ "inputFormat",      std::string("text")           },
		{ "outputLocation",   std::string("replaceInput")   },
		{ "outputFormat",     std::string("text")           },
		{ "outputCaret",      std::string("afterOutput")    },
		{ "outputReuse",      std::string("reuseAvailable") },
		{ "autoScrollOutput", false                         },
	});
	OAK_ASSERT_EQ(command::ignored_settings(plist, false).size(), 0);
}

// The two shapes that carry a key without asking for anything: an autoRefresh
// that lists no event, and a flag written out as off. Both are silent because
// the comparison is of parsed values — an empty array leaves the bitmask at
// never, and false is what the flags already default to.
void test_an_empty_auto_refresh_and_flags_left_off_are_silent ()
{
	auto const plist = command_plist({
		{ "autoRefresh",             plist::array_t{ } },
		{ "autoScrollOutput",        false             },
		{ "disableOutputAutoIndent", false             },
		{ "disableJavaScriptAPI",    false             },
	});
	OAK_ASSERT_EQ(command::ignored_settings(plist, false).size(), 0);
	OAK_ASSERT_EQ(command::ignored_settings(plist, true).size(), 0);
}

// Nothing is ignored while the command runs inside TextMate, however loudly it
// declares the keys.
void test_an_in_process_command_ignores_nothing ()
{
	plist::dictionary_t plist = command_plist({ { "outputLocation", std::string("newWindow") } });
	plist["runLocation"] = std::string("inProcess");
	OAK_ASSERT_EQ(command::ignored_settings(plist, false).size(), 0);
	plist.erase("runLocation");
	OAK_ASSERT_EQ(command::ignored_settings(plist, false).size(), 0);
}

void test_each_ignored_setting_is_named ()
{
	struct { char const* key; plist::any_t value; } const settings[] =
	{
		{ "input",                   std::string("document")     },
		{ "fallbackInput",           std::string("line")         },
		{ "inputFormat",             std::string("xml")          },
		{ "outputLocation",          std::string("newWindow")    },
		{ "outputFormat",            std::string("html")         },
		{ "outputCaret",             std::string("selectOutput") },
		{ "outputReuse",             std::string("reuseNone")    },
		{ "autoRefresh",             plist::array_t{ std::string("documentSaved") } },
		{ "autoScrollOutput",        true                        },
		{ "disableOutputAutoIndent", true                        },
		{ "disableJavaScriptAPI",    true                        },
	};

	for(auto const& setting : settings)
		OAK_ASSERT_EQ(command::ignored_settings(command_plist({ { setting.key, setting.value } }), false), (std::vector<std::string>{ setting.key }));
}

void test_several_ignored_settings_are_all_named ()
{
	auto const plist = command_plist({
		{ "input",          std::string("document")  },
		{ "outputLocation", std::string("newWindow") },
		{ "outputFormat",   std::string("html")      },
	});
	OAK_ASSERT_EQ(command::ignored_settings(plist, false), (std::vector<std::string>{ "input", "outputLocation", "outputFormat" }));
}

// A drag command parses with its own defaults — no input, insert a snippet at
// the caret — so the same three values that would be a conflict above are this
// item kind saying nothing at all.
void test_a_drag_command_is_measured_against_its_own_defaults ()
{
	auto const plist = command_plist({
		{ "input",          std::string("none")    },
		{ "fallbackInput",  std::string("none")    },
		{ "outputLocation", std::string("atCaret") },
		{ "outputFormat",   std::string("snippet") },
	});
	OAK_ASSERT_EQ(command::ignored_settings(plist, true).size(), 0);
	OAK_ASSERT_EQ(command::ignored_settings(plist, false), (std::vector<std::string>{ "input", "fallbackInput", "outputLocation", "outputFormat" }));
}

// The warning has to see what the command will actually run with, which for a
// version 1 command is the converted plist rather than the one on disk.
void test_a_version_1_command_is_converted_before_measuring ()
{
	plist::dictionary_t plist = command_plist({ });
	plist["version"] = int32_t(1);
	plist["output"]  = std::string("showAsTooltip");
	OAK_ASSERT_EQ(command::ignored_settings(plist, false), (std::vector<std::string>{ "outputLocation" }));
}
