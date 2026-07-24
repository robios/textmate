#include "../src/gutter_diff.h"
#include "../src/drivers/api.h"
#include <io/exec.h>
#include <text/format.h>
#include <test/jail.h>

using scm::gutter_diff::blob_for_ref;
using scm::gutter_diff::change;
using scm::gutter_diff::diff_bytes;
using scm::gutter_diff::invalidate_repo;
using scm::gutter_diff::result_t;

namespace
{
	// What the diff service does on its compute queue: fetch the blob
	// the ref names — a real `git show <ref>:<path>` against a real
	// repository, which is what these tests are here to exercise — and
	// diff the buffer against it.
	result_t marks_against_head (std::string const& root, std::string const& rel,
	                             std::string const& current)
	{
		return diff_bytes(blob_for_ref(root, "HEAD", rel), current);
	}

	void bootstrap_repo (test::jail_t const& jail, std::string const& git,
	                     std::string const& path, std::string const& content)
	{
		std::string const script = text::format(
			"{ cd '%1$s' "
			"&& '%2$s' init -b master "
			"&& '%2$s' config user.email 'test@example.com' "
			"&& '%2$s' config user.name 'Test Test' "
			"&& '%2$s' config commit.gpgsign false "
			"&& printf %%s '%3$s' > '%4$s' "
			"&& '%2$s' add '%4$s' "
			"&& '%2$s' commit -m initial "
			"; } >/dev/null",
			jail.path().c_str(), git.c_str(), content.c_str(), path.c_str());
		io::exec("/bin/sh", "-c", script.c_str(), nullptr);
	}
}

void test_gutter_diff_integration_modified_buffer ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	bootstrap_repo(jail, git, "file.txt", "a\nb\nc\n");
	invalidate_repo(jail.path());

	result_t r = marks_against_head(jail.path(), "file.txt", "a\nB\nc\n");
	OAK_ASSERT_EQ(r.size(), 1);
	OAK_ASSERT_EQ(r[2], change::modified);
}

void test_gutter_diff_integration_untracked_file_all_added ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	bootstrap_repo(jail, git, "file.txt", "x\n");
	invalidate_repo(jail.path());

	// new.txt was never committed; HEAD blob fetch fails → empty
	// blob → diff against the buffer text shows everything as added.
	result_t r = marks_against_head(jail.path(), "new.txt", "alpha\nbeta\n");
	OAK_ASSERT_EQ(r.size(), 2);
	OAK_ASSERT_EQ(r[1], change::added);
	OAK_ASSERT_EQ(r[2], change::added);
}

void test_gutter_diff_integration_clean_buffer_no_marks ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	bootstrap_repo(jail, git, "file.txt", "a\nb\nc\n");
	invalidate_repo(jail.path());

	result_t r = marks_against_head(jail.path(), "file.txt", "a\nb\nc\n");
	OAK_ASSERT(r.empty());
}
