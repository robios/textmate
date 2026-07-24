#include "../src/git_query.h"
#include "../src/gutter_diff.h"
#include "../src/drivers/api.h"
#include <io/exec.h>
#include <text/format.h>
#include <test/jail.h>

using namespace scm::git_query;

namespace
{
	void run_sh (std::string const& script)
	{
		io::exec("/bin/sh", "-c", script.c_str(), nullptr);
	}

	// A repo with two commits touching file.txt: v1 then v2.
	void bootstrap_two_commit_repo (test::jail_t const& jail, std::string const& git)
	{
		run_sh(text::format(
			"{ cd '%1$s' "
			"&& '%2$s' init -b master "
			"&& '%2$s' config user.email 'test@example.com' "
			"&& '%2$s' config user.name 'Test Test' "
			"&& '%2$s' config commit.gpgsign false "
			"&& printf 'one\\ntwo\\n' > file.txt "
			"&& '%2$s' add file.txt && '%2$s' commit -m first "
			"&& printf 'one\\nTWO\\n' > file.txt "
			"&& '%2$s' add file.txt && '%2$s' commit -m second "
			"; } >/dev/null 2>&1",
			jail.path().c_str(), git.c_str()));
	}
}

void test_git_query_head_and_log ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	bootstrap_two_commit_repo(jail, git);

	std::string const head = head_commit(jail.path());
	OAK_ASSERT_EQ(head.size(), 40);

	auto const commits = recent_commits(jail.path(), 20);
	OAK_ASSERT_EQ(commits.size(), 2);
	OAK_ASSERT_EQ(commits[0].sha, head);
	OAK_ASSERT_EQ(commits[0].subject, "second");
	OAK_ASSERT_EQ(commits[1].subject, "first");

	OAK_ASSERT(is_ancestor(jail.path(), commits[1].sha, commits[0].sha));
	OAK_ASSERT(is_ancestor(jail.path(), head, head));
	OAK_ASSERT(!is_ancestor(jail.path(), commits[0].sha, commits[1].sha));
}

void test_git_query_staged_changes ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	bootstrap_two_commit_repo(jail, git);

	OAK_ASSERT(!has_staged_changes(jail.path(), "file.txt"));

	run_sh(text::format("{ cd '%1$s' && printf 'one\\nTWO\\nthree\\n' > file.txt && '%2$s' add file.txt; } >/dev/null 2>&1", jail.path().c_str(), git.c_str()));
	OAK_ASSERT(has_staged_changes(jail.path(), "file.txt"));
	OAK_ASSERT(!has_staged_changes(jail.path(), "other.txt"));
}

void test_git_query_blob_for_older_ref ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	bootstrap_two_commit_repo(jail, git);
	scm::gutter_diff::invalidate_repo(jail.path());

	auto const commits = recent_commits(jail.path(), 20);
	OAK_ASSERT_EQ(commits.size(), 2);

	bool tracked = false;
	OAK_ASSERT_EQ(scm::gutter_diff::blob_for_ref(jail.path(), "HEAD", "file.txt", &tracked), "one\nTWO\n");
	OAK_ASSERT(tracked);
	OAK_ASSERT_EQ(scm::gutter_diff::blob_for_ref(jail.path(), commits[1].sha, "file.txt", &tracked), "one\ntwo\n");
	OAK_ASSERT(tracked);

	scm::gutter_diff::blob_for_ref(jail.path(), "HEAD", "missing.txt", &tracked);
	OAK_ASSERT(!tracked);
}
