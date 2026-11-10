#include <lsp/LSPWorkspaceRoot.h>
#include <io/path.h>
#include <test/jail.h>

// The jail lives in the temporary folder, outside the real home folder, so
// the marker walk above it finds nothing. ‘home’ is passed explicitly, which
// lets the jail stand in for it.

void test_marker_root_finds_nearest_marker ()
{
	test::jail_t jail;
	jail.mkdir("proj/.git");
	jail.touch("proj/sub/package.json");
	jail.touch("proj/sub/src/main.js");
	jail.touch("proj/other/file.c");

	OAK_ASSERT_EQ(lsp::marker_workspace_root(jail.path("proj/sub/src/main.js")), jail.path("proj/sub"));
	OAK_ASSERT_EQ(lsp::marker_workspace_root(jail.path("proj/other/file.c")),    jail.path("proj"));
}

void test_marker_root_is_empty_without_marker ()
{
	test::jail_t jail;
	jail.touch("notes/todo.txt");

	OAK_ASSERT_EQ(lsp::marker_workspace_root(jail.path("notes/todo.txt")), "");
}

void test_shared_folder_has_no_parent_directory_fallback ()
{
	test::jail_t jail;
	jail.touch("home/Documents/letter.md");

	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder("", jail.path("home/Documents/letter.md"), jail.path("home")), "");
}

void test_shared_folder_uses_marker_root ()
{
	test::jail_t jail;
	jail.mkdir("home/proj/.git");
	jail.touch("home/proj/src/main.c");

	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder("", jail.path("home/proj/src/main.c"), jail.path("home")), jail.path("home/proj"));
}

void test_shared_folder_never_returns_home ()
{
	// A dotfiles repository makes the home folder itself a marker root.
	test::jail_t jail;
	jail.mkdir("home/.git");
	jail.touch("home/notes.txt");
	jail.touch("home/scratch/x.py");

	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder("", jail.path("home/notes.txt"),    jail.path("home")), "");
	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder("", jail.path("home/scratch/x.py"), jail.path("home")), "");
}

void test_shared_folder_rejects_ancestors_of_home ()
{
	test::jail_t jail;
	jail.mkdir("Users/.git");
	jail.touch("Users/me/file.txt");

	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder("", jail.path("Users/me/file.txt"), jail.path("Users/me")), "");
	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder("/", jail.path("Users/me/file.txt"), jail.path("Users/me")), "");
}

void test_shared_folder_prefers_configured_root ()
{
	test::jail_t jail;
	jail.mkdir("home/proj/.git");
	jail.touch("home/proj/lib/a.rb");

	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder(jail.path("home/proj/lib/"), jail.path("home/proj/lib/a.rb"), jail.path("home")), jail.path("home/proj/lib"));
}

void test_shared_folder_falls_back_to_marker_when_configured_root_is_rejected ()
{
	test::jail_t jail;
	jail.mkdir("home/proj/.git");
	jail.touch("home/proj/lib/a.rb");

	std::string const file = jail.path("home/proj/lib/a.rb"), home = jail.path("home");
	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder(home,                        file, home), jail.path("home/proj"));
	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder("relative/dir",              file, home), jail.path("home/proj"));
	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder(jail.path("home/gone/sub"),  file, home), jail.path("home/proj"));
}

void test_shared_folder_rejects_missing_configured_root ()
{
	// The server would watch the nearest existing ancestor (home) instead.
	test::jail_t jail;
	jail.touch("home/notes/todo.txt");

	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder(jail.path("home/gone/sub"), jail.path("home/notes/todo.txt"), jail.path("home")), "");
}

void test_shared_folder_rejects_symlink_to_home ()
{
	test::jail_t jail;
	jail.touch("home/notes/todo.txt");
	jail.ln("alias", "home");

	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder(jail.path("alias"), jail.path("home/notes/todo.txt"), jail.path("home")), "");
}

void test_shared_folder_rejects_home_given_through_symlink_or_trailing_slash ()
{
	test::jail_t jail;
	jail.mkdir("realhome/.git");
	jail.touch("realhome/notes.txt");
	jail.ln("homelink", "realhome");

	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder("", jail.path("realhome/notes.txt"), jail.path("homelink")),        "");
	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder("", jail.path("realhome/notes.txt"), jail.path("realhome") + "/"),  "");
}

void test_shared_folder_outside_home ()
{
	test::jail_t jail;
	jail.mkdir("home");
	jail.touch("srv/app/go.mod");
	jail.touch("srv/app/main.go");

	OAK_ASSERT_EQ(lsp::shared_server_workspace_folder("", jail.path("srv/app/main.go"), jail.path("home")), jail.path("srv/app"));
}
