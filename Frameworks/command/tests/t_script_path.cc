#include <command/runner.h>
#include <io/path.h>

// The path a runLocation:terminal command types onto the user's prompt. It has
// to be readable, and it has to keep identifying the script exactly: the cache
// reuses whatever executable already sits at the path without comparing its
// contents, so anything that shortens the digest eventually runs the wrong one.

static std::string const kBody = "#!/bin/bash\necho one\n";
static size_t const kSHA1Length = 40;

static std::string name_for (std::string const& body, std::string const& commandName)
{
	return path::name(command::create_named_script_path(body, commandName));
}

void test_named_script_path_keeps_the_full_digest ()
{
	std::string const name = name_for(kBody, "Run Tests");
	OAK_ASSERT_EQ(name.substr(0, std::string("Run_Tests-").size()), "Run_Tests-");
	OAK_ASSERT_EQ(name.size(), std::string("Run_Tests-").size() + kSHA1Length);

	// …and it is the same digest the anonymous path uses.
	OAK_ASSERT_EQ(name.substr(name.size() - kSHA1Length), path::name(command::create_script_path(kBody)));
}

void test_named_script_path_is_content_addressed ()
{
	std::string const one   = command::create_named_script_path("#!/bin/bash\necho one\n", "Same Name");
	std::string const other = command::create_named_script_path("#!/bin/bash\necho two\n", "Same Name");
	OAK_ASSERT_NE(one, other);
	OAK_ASSERT_EQ(one, command::create_named_script_path("#!/bin/bash\necho one\n", "Same Name"));

	OAK_ASSERT_EQ(path::content(one), "#!/bin/bash\necho one\n");
	OAK_ASSERT_EQ(path::content(other), "#!/bin/bash\necho two\n");
}

void test_named_script_path_sanitizes_the_name ()
{
	// Spaces and punctuation would have to be quoted to be typed; a leading dot
	// would hide the file; neither may leave the directory.
	std::string const name = name_for(kBody, "  ../Ünicode & spaces!!  ");
	OAK_ASSERT_EQ(name.find('/'), std::string::npos);
	OAK_ASSERT_NE(name[0], '.');
	OAK_ASSERT_NE(name[0], '_');
	OAK_ASSERT_EQ(name, "nicode_spaces-" + name.substr(name.size() - kSHA1Length));
}

void test_named_script_path_caps_the_name_not_the_digest ()
{
	std::string const name = name_for(kBody, std::string(200, 'x'));
	OAK_ASSERT_EQ(name.size(), 32 + 1 + kSHA1Length);
}

void test_named_script_path_survives_a_nameless_command ()
{
	std::string const name = name_for(kBody, NULL_STR);
	OAK_ASSERT_EQ(name, "command-" + name.substr(name.size() - kSHA1Length));

	// A name with nothing usable in it lands in the same place.
	OAK_ASSERT_EQ(name_for(kBody, "!!!"), name);
}

void test_named_script_path_is_executable ()
{
	OAK_ASSERT(path::is_executable(command::create_named_script_path(kBody, "Run Tests")));
}
