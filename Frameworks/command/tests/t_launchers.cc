#include <command/launcher.h>
#include <test/bundle_index.h>

// What a launcher has to satisfy to reach the Terminal menu, and — the part
// worth pinning — what it must not have to: agreeing with the other launchers
// about scope. bundles::query keeps only the highest-ranked scope matches by
// default, which would mean the moment a language-specific launcher matched,
// every general one silently left the menu.

void setup_launcher_fixtures ()
{
	static std::string GeneralLauncher =
		"{	command       = \"#!/bin/sh\\ntrue\\n\";\n"
		"	semanticClass = 'terminal.launcher';\n"
		"	name          = 'General Launcher';\n"
		"	runLocation   = 'terminal';\n"
		"	uuid          = 'B0BB1E5E-0000-4000-8000-000000000001';\n"
		"}\n";

	// Declares a sub-class of the same root, to show the prefix match, and a
	// scope narrow enough to outrank the general one above.
	static std::string RubyLauncher =
		"{	command       = \"#!/bin/sh\\ntrue\\n\";\n"
		"	semanticClass = 'terminal.launcher.ruby';\n"
		"	name          = 'Ruby Launcher';\n"
		"	runLocation   = 'terminal';\n"
		"	scope         = 'attr.test.launchers.ruby';\n"
		"	uuid          = 'B0BB1E5E-0000-4000-8000-000000000002';\n"
		"}\n";

	static std::string InProcessImpostor =
		"{	command       = \"#!/bin/sh\\ntrue\\n\";\n"
		"	semanticClass = 'terminal.launcher.impostor';\n"
		"	name          = 'In Process Impostor';\n"
		"	uuid          = 'B0BB1E5E-0000-4000-8000-000000000003';\n"
		"}\n";

	static std::string HiddenLauncher =
		"{	command       = \"#!/bin/sh\\ntrue\\n\";\n"
		"	semanticClass = 'terminal.launcher.hidden';\n"
		"	hideFromUser  = 1;\n"
		"	name          = 'Hidden Launcher';\n"
		"	runLocation   = 'terminal';\n"
		"	uuid          = 'B0BB1E5E-0000-4000-8000-000000000004';\n"
		"}\n";

	// A terminal command that never claimed to be a launcher: the class is what
	// puts an item in this menu, not runLocation.
	static std::string UnclassedTerminalCommand =
		"{	command       = \"#!/bin/sh\\ntrue\\n\";\n"
		"	name          = 'Unclassed Terminal Command';\n"
		"	runLocation   = 'terminal';\n"
		"	uuid          = 'B0BB1E5E-0000-4000-8000-000000000005';\n"
		"}\n";

	// Disabled items never reach a query that did not ask for them, but a menu
	// is exactly where forgetting that would show.
	static std::string DisabledLauncher =
		"{	command       = \"#!/bin/sh\\ntrue\\n\";\n"
		"	semanticClass = 'terminal.launcher.disabled';\n"
		"	isDisabled    = 1;\n"
		"	name          = 'Disabled Launcher';\n"
		"	runLocation   = 'terminal';\n"
		"	uuid          = 'B0BB1E5E-0000-4000-8000-000000000007';\n"
		"}\n";

	// Right class, right runLocation, wrong kind of item.
	static std::string LauncherDragCommand =
		"{	command       = \"#!/bin/sh\\ntrue\\n\";\n"
		"	semanticClass = 'terminal.launcher.drop';\n"
		"	draggedFileExtensions = ( launcher );\n"
		"	name          = 'Launcher Drag Command';\n"
		"	runLocation   = 'terminal';\n"
		"	uuid          = 'B0BB1E5E-0000-4000-8000-000000000006';\n"
		"}\n";

	test::bundle_index_t bundleIndex;
	bundleIndex.add(bundles::kItemTypeCommand,     GeneralLauncher);
	bundleIndex.add(bundles::kItemTypeCommand,     RubyLauncher);
	bundleIndex.add(bundles::kItemTypeCommand,     InProcessImpostor);
	bundleIndex.add(bundles::kItemTypeCommand,     HiddenLauncher);
	bundleIndex.add(bundles::kItemTypeCommand,     UnclassedTerminalCommand);
	bundleIndex.add(bundles::kItemTypeCommand,     DisabledLauncher);
	bundleIndex.add(bundles::kItemTypeDragCommand, LauncherDragCommand);
	bundleIndex.commit();
}

static std::set<std::string> launcher_names (std::string const& scope)
{
	std::set<std::string> res;
	for(auto const& item : command::terminal_launchers(scope))
		res.insert(item->name());
	return res;
}

void test_unscoped_launcher_is_found ()
{
	OAK_ASSERT_EQ(launcher_names("attr.test.launchers"), (std::set<std::string>{ "General Launcher" }));
}

// The no-window case: with nothing open the menu asks against an empty scope,
// where a launcher that named the file types it applies to correctly has none.
void test_empty_scope_finds_only_the_unscoped_launcher ()
{
	OAK_ASSERT_EQ(launcher_names(""), (std::set<std::string>{ "General Launcher" }));
}

// The point of asking bundles::query not to filter by scope rank: the Ruby
// launcher outranks the general one and would otherwise be the whole menu.
void test_a_specific_launcher_does_not_hide_a_general_one ()
{
	OAK_ASSERT_EQ(launcher_names("attr.test.launchers.ruby"), (std::set<std::string>{ "General Launcher", "Ruby Launcher" }));
}

void test_in_process_hidden_and_disabled_commands_are_left_out ()
{
	auto const names = launcher_names("attr.test.launchers.ruby");
	OAK_ASSERT(names.find("In Process Impostor") == names.end());
	OAK_ASSERT(names.find("Hidden Launcher")     == names.end());
	OAK_ASSERT(names.find("Disabled Launcher")   == names.end());
}

void test_a_terminal_command_without_the_class_is_left_out ()
{
	auto const names = launcher_names("attr.test.launchers.ruby");
	OAK_ASSERT(names.find("Unclassed Terminal Command") == names.end());
}

// A drop handler may perfectly well run in the terminal, but it is offered by
// dropping a file on the editor, not by picking it from a menu.
void test_a_drag_command_is_left_out ()
{
	auto const names = launcher_names("attr.test.launchers.ruby");
	OAK_ASSERT(names.find("Launcher Drag Command") == names.end());
}
