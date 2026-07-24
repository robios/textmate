#include "../src/git_query.h"
#include "../src/gutter_diff.h"
#include "../src/drivers/api.h"
#include "../src/fs_events.h"
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

void test_git_query_rev_parse ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	bootstrap_two_commit_repo(jail, git);

	auto const commits = recent_commits(jail.path(), 20);
	OAK_ASSERT_EQ(commits.size(), 2);

	OAK_ASSERT_EQ(rev_parse(jail.path(), "HEAD"), commits[0].sha);
	OAK_ASSERT_EQ(rev_parse(jail.path(), "HEAD~1"), commits[1].sha);
	OAK_ASSERT_EQ(rev_parse(jail.path(), commits[1].sha), commits[1].sha);

	// Reaching back past the root commit resolves to nothing, which is
	// what sends a relative base back to HEAD.
	OAK_ASSERT_EQ(rev_parse(jail.path(), "HEAD~2"), NULL_STR);
	OAK_ASSERT_EQ(rev_parse(jail.path(), "no-such-ref"), NULL_STR);
}

// HEAD~1 means the FIRST PARENT, which is not the same as the second
// entry of `git log`: the default log order mixes both sides of a merge
// by date, so a merge commit at HEAD can easily list the merged branch's
// tip second. Resolving the spec through git is what keeps them apart.
void test_git_query_rev_parse_follows_first_parent ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	run_sh(text::format(
		"{ cd '%1$s' "
		"&& '%2$s' init -b master "
		"&& '%2$s' config user.email 'test@example.com' "
		"&& '%2$s' config user.name 'Test Test' "
		"&& '%2$s' config commit.gpgsign false "
		"&& printf 'base\\n' > file.txt "
		"&& '%2$s' add file.txt && '%2$s' commit -m base "
		"&& '%2$s' checkout -b side "
		"&& printf 'side\\n' > side.txt "
		"&& '%2$s' add side.txt && '%2$s' commit -m side "
		"&& '%2$s' checkout master "
		"&& printf 'main\\n' > main.txt "
		"&& '%2$s' add main.txt && '%2$s' commit -m mainline "
		"&& '%2$s' merge --no-ff -m merge side "
		"; } >/dev/null 2>&1",
		jail.path().c_str(), git.c_str()));

	std::string const first_parent = rev_parse(jail.path(), "HEAD~1");
	std::string const second_parent = rev_parse(jail.path(), "HEAD^2");
	OAK_ASSERT_EQ(first_parent.size(), 40);
	OAK_ASSERT_EQ(rev_parse(jail.path(), "HEAD^1"), first_parent);
	OAK_ASSERT(first_parent != second_parent);
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

// A linked worktree keeps HEAD, the index and its refs OUTSIDE the
// worktree — under <main>/.git — so anything watching only the worktree
// never sees a commit or a `git add`. These two cover the pieces that
// tell the watcher where to look and what a change there means.
void test_git_metadata_dir_for_linked_worktree ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	std::string const main   = path::join(jail.path(), "main");
	std::string const linked = path::join(jail.path(), "linked");

	run_sh(text::format(
		"{ mkdir -p '%1$s' && cd '%1$s' "
		"&& '%3$s' init -b master "
		"&& '%3$s' config user.email 'test@example.com' "
		"&& '%3$s' config user.name 'Test Test' "
		"&& '%3$s' config commit.gpgsign false "
		"&& printf 'one\\ntwo\\n' > file.txt "
		"&& '%3$s' add file.txt && '%3$s' commit -m first "
		"&& '%3$s' worktree add -b side '%2$s' "
		"; } >/dev/null 2>&1",
		main.c_str(), linked.c_str(), git.c_str()));

	// An ordinary repository keeps its metadata below the root.
	OAK_ASSERT_EQ(scm::git_metadata_dir(main), path::join(main, ".git"));

	// The linked worktree's `.git` is a file pointing elsewhere, and the
	// directory it leads to is not below the worktree at all.
	std::string const meta = scm::git_metadata_dir(linked);
	OAK_ASSERT_EQ(meta, path::join(main, ".git"));
	OAK_ASSERT(path::relative_to(meta, linked).compare(0, 2, "..") == 0);

	// Not a repository at all.
	OAK_ASSERT_EQ(scm::git_metadata_dir(jail.path()), NULL_STR);
}

void test_repo_meta_path_classification ()
{
	// Paths are judged relative to the metadata directory the watcher was
	// pointed at, in the space FSEvents reports — which prefixes the
	// volume's mount point, and which names the DIRECTORY holding a
	// change rather than the file.
	std::string const meta = "/System/Volumes/Data/Users/me/repo/.git";

	OAK_ASSERT(scm::is_repo_meta_path(meta, meta));                     // HEAD, index, packed-refs all live here
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta + "/refs/heads"));     // a commit moved a branch
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta + "/refs"));
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta + "/worktrees/wt"));   // a linked worktree's own HEAD and index

	// File-granular forms, in case a future stream asks for them.
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta + "/HEAD"));
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta + "/index"));
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta + "/packed-refs"));
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta + "/refs/heads/main"));
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta + "/worktrees/wt/HEAD"));
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta + "/worktrees/wt/index"));

	// The noisy neighbours, which churn on their own schedule.
	OAK_ASSERT(!scm::is_repo_meta_path(meta, meta + "/objects"));
	OAK_ASSERT(!scm::is_repo_meta_path(meta, meta + "/objects/ab"));
	OAK_ASSERT(!scm::is_repo_meta_path(meta, meta + "/logs/refs/heads"));
	OAK_ASSERT(!scm::is_repo_meta_path(meta, meta + "/worktrees/wt/logs"));
	OAK_ASSERT(!scm::is_repo_meta_path(meta, meta + "/refs/tags"));

	// Outside the watched directory, above it, and no directory at all.
	OAK_ASSERT(!scm::is_repo_meta_path(meta, "/System/Volumes/Data/Users/me/repo/src/main.cc"));
	OAK_ASSERT(!scm::is_repo_meta_path(meta, "/System/Volumes/Data/Users/me/other/.git/HEAD"));
	OAK_ASSERT(!scm::is_repo_meta_path(meta, "/System/Volumes/Data/Users/me"));
	OAK_ASSERT(!scm::is_repo_meta_path(NULL_STR, meta + "/HEAD"));

	// A submodule is watched AT its own metadata directory, so its name
	// never has to be parsed out of the path — which matters because it
	// cannot be: these two are the same shape and mean different things.
	std::string const nested = "/System/Volumes/Data/Users/me/super/.git/modules/vendor/lib";
	OAK_ASSERT(scm::is_repo_meta_path(nested, nested));
	OAK_ASSERT(scm::is_repo_meta_path(nested, nested + "/HEAD"));
	OAK_ASSERT(scm::is_repo_meta_path(nested, nested + "/index"));
	OAK_ASSERT(scm::is_repo_meta_path(nested, nested + "/refs/heads"));
	OAK_ASSERT(!scm::is_repo_meta_path(nested, nested + "/objects/ab"));
	OAK_ASSERT(!scm::is_repo_meta_path(nested, nested + "/logs/HEAD"));

	// One submodule named `vendor/lib` versus submodule `b` inside `a`:
	// measured from its own root, each sees only its own metadata, and
	// neither is mistaken for the other.
	std::string const inner = "/System/Volumes/Data/Users/me/super/.git/modules/a/modules/b";
	OAK_ASSERT(scm::is_repo_meta_path(inner, inner + "/HEAD"));
	OAK_ASSERT(!scm::is_repo_meta_path(nested, inner + "/HEAD"));
	OAK_ASSERT(!scm::is_repo_meta_path(inner, nested + "/HEAD"));
}

// The integration half: run the real commands from the linked worktree
// and confirm both that git writes outside the worktree and that the
// directory an event would name is classified as a metadata change.
void test_linked_worktree_add_and_commit_reach_the_watcher ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	std::string const main   = path::join(jail.path(), "main");
	std::string const linked = path::join(jail.path(), "linked");

	run_sh(text::format(
		"{ mkdir -p '%1$s' && cd '%1$s' "
		"&& '%3$s' init -b master "
		"&& '%3$s' config user.email 'test@example.com' "
		"&& '%3$s' config user.name 'Test Test' "
		"&& '%3$s' config commit.gpgsign false "
		"&& printf 'one\\ntwo\\n' > file.txt "
		"&& '%3$s' add file.txt && '%3$s' commit -m first "
		"&& '%3$s' worktree add -b side '%2$s' "
		"; } >/dev/null 2>&1",
		main.c_str(), linked.c_str(), git.c_str()));

	std::string const meta = scm::git_metadata_dir(linked);
	OAK_ASSERT(meta != NULL_STR);

	auto const modified_since = [](std::string const& path, time_t since) -> bool {
		struct stat buf;
		return stat(path.c_str(), &buf) == 0 && buf.st_mtime >= since;
	};

	std::string const index = path::join(meta, "worktrees/linked/index");
	std::string const ref   = path::join(meta, "refs/heads/side");
	OAK_ASSERT(path::exists(index));

	// `git add` rewrites the worktree's own index, which lives outside it.
	time_t const beforeAdd = time(nullptr);
	run_sh(text::format("{ cd '%1$s' && printf 'one\\nTWO\\n' > file.txt && '%2$s' add file.txt; } >/dev/null 2>&1", linked.c_str(), git.c_str()));
	OAK_ASSERT(modified_since(index, beforeAdd));
	OAK_ASSERT(scm::is_repo_meta_path(meta, path::parent(index)));

	// Committing moves the branch ref, which lives outside it too — and
	// note HEAD itself does not move, being a symref to that branch.
	time_t const beforeCommit = time(nullptr);
	run_sh(text::format("{ cd '%1$s' && '%2$s' commit -m second; } >/dev/null 2>&1", linked.c_str(), git.c_str()));
	OAK_ASSERT(modified_since(ref, beforeCommit));
	OAK_ASSERT(scm::is_repo_meta_path(meta, path::parent(ref)));

	// The point of the finding: none of this is below the worktree, so a
	// watcher rooted there sees nothing of either operation.
	OAK_ASSERT(path::relative_to(index, linked).compare(0, 2, "..") == 0);
	OAK_ASSERT(path::relative_to(ref, linked).compare(0, 2, "..") == 0);
}

// The commit alone cannot tell a branch switch from a commit, which is
// what these two histories are built to demonstrate.
void test_symbolic_head_and_branch_switches ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	run_sh(text::format(
		"{ cd '%1$s' "
		"&& '%2$s' init -b master "
		"&& '%2$s' config user.email 'test@example.com' "
		"&& '%2$s' config user.name 'Test Test' "
		"&& '%2$s' config commit.gpgsign false "
		"&& printf 'base\\n' > file.txt "
		"&& '%2$s' add file.txt && '%2$s' commit -m base "
		"&& '%2$s' branch twin "                      // same commit, different branch
		"&& '%2$s' checkout -b ahead "
		"&& printf 'ahead\\n' >> file.txt "
		"&& '%2$s' add file.txt && '%2$s' commit -m ahead "
		"&& '%2$s' checkout master "
		"; } >/dev/null 2>&1",
		jail.path().c_str(), git.c_str()));

	OAK_ASSERT_EQ(symbolic_head(jail.path()), "refs/heads/master");

	std::string const masterSha = head_commit(jail.path());

	// Switching to a branch at the SAME commit: the sha does not move at
	// all, so nothing that watches only the sha sees a switch.
	run_sh(text::format("{ cd '%1$s' && '%2$s' checkout twin; } >/dev/null 2>&1", jail.path().c_str(), git.c_str()));
	OAK_ASSERT_EQ(symbolic_head(jail.path()), "refs/heads/twin");
	OAK_ASSERT_EQ(head_commit(jail.path()), masterSha);

	// Switching to a branch AHEAD of where we were: the sha moves onto a
	// descendant, which reads exactly like a commit landing.
	run_sh(text::format("{ cd '%1$s' && '%2$s' checkout ahead; } >/dev/null 2>&1", jail.path().c_str(), git.c_str()));
	OAK_ASSERT_EQ(symbolic_head(jail.path()), "refs/heads/ahead");
	std::string const aheadSha = head_commit(jail.path());
	OAK_ASSERT(aheadSha != masterSha);
	OAK_ASSERT(is_ancestor(jail.path(), masterSha, aheadSha));

	// Detaching reports no branch at all.
	run_sh(text::format("{ cd '%1$s' && '%2$s' checkout --detach; } >/dev/null 2>&1", jail.path().c_str(), git.c_str()));
	OAK_ASSERT_EQ(symbolic_head(jail.path()), NULL_STR);
}

void test_classify_head_change ()
{
	using scm::git_query::head_change;
	std::string const a = "aaaaaaaa", b = "bbbbbbbb";
	std::string const main = "refs/heads/main", side = "refs/heads/side";

	// Nothing observed yet, and nothing moved.
	OAK_ASSERT(classify_head_change(NULL_STR, NULL_STR, main, a, false) == head_change::none);
	OAK_ASSERT(classify_head_change(main, a, main, a, true) == head_change::none);

	// A commit on this branch.
	OAK_ASSERT(classify_head_change(main, a, main, b, true) == head_change::committed);

	// The two the sha alone gets wrong: a switch that moves no commit,
	// and a switch onto a descendant, which ancestry calls a commit.
	OAK_ASSERT(classify_head_change(main, a, side, a, true) == head_change::switched);
	OAK_ASSERT(classify_head_change(main, a, side, b, true) == head_change::switched);

	// Same branch, no longer a descendant: reset, rebase, amend.
	OAK_ASSERT(classify_head_change(main, a, main, b, false) == head_change::rewritten);

	// Into and out of a detached HEAD are switches too.
	OAK_ASSERT(classify_head_change(main, a, NULL_STR, a, true) == head_change::switched);
	OAK_ASSERT(classify_head_change(NULL_STR, a, main, a, true) == head_change::switched);
	OAK_ASSERT(classify_head_change(NULL_STR, a, NULL_STR, b, true) == head_change::committed);
}

// A submodule's `.git` is a file too, pointing at
// <superproject>/.git/modules/<name> — outside the submodule, and a
// different shape from a linked worktree's.
void test_git_metadata_dir_for_submodule ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	std::string const lib   = path::join(jail.path(), "lib");
	std::string const super = path::join(jail.path(), "super");

	run_sh(text::format(
		"{ mkdir -p '%1$s' '%2$s' "
		"&& cd '%1$s' && '%3$s' init -b master "
		"&& '%3$s' config user.email 'test@example.com' && '%3$s' config user.name 'Test Test' "
		"&& '%3$s' config commit.gpgsign false "
		"&& printf 'lib\\n' > lib.txt && '%3$s' add lib.txt && '%3$s' commit -m lib "
		"&& cd '%2$s' && '%3$s' init -b master "
		"&& '%3$s' config user.email 'test@example.com' && '%3$s' config user.name 'Test Test' "
		"&& '%3$s' config commit.gpgsign false "
		"&& printf 'super\\n' > s.txt && '%3$s' add s.txt && '%3$s' commit -m super "
		"&& '%3$s' -c protocol.file.allow=always submodule add '%1$s' sub "
		"&& '%3$s' commit -m addsub "
		"; } >/dev/null 2>&1",
		lib.c_str(), super.c_str(), git.c_str()));

	std::string const sub = path::join(super, "sub");
	if(!path::exists(path::join(sub, ".git")))
		return; // submodules disabled in this environment

	std::string const meta = scm::git_metadata_dir(sub);
	OAK_ASSERT_EQ(meta, path::join(super, ".git/modules/sub"));

	// Outside the submodule, so a watcher rooted there sees none of it.
	OAK_ASSERT(path::relative_to(meta, sub).compare(0, 2, "..") == 0);

	// And the events it would produce classify as metadata changes — the
	// shape being `modules/<name>/…` after the superproject's `/.git`.
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta));
	OAK_ASSERT(scm::is_repo_meta_path(meta, path::join(meta, "HEAD")));
	OAK_ASSERT(scm::is_repo_meta_path(meta, path::join(meta, "index")));
	OAK_ASSERT(scm::is_repo_meta_path(meta, path::join(meta, "refs/heads")));
}

// Git names a submodule by its PATH, so `git submodule add … vendor/lib`
// puts its metadata at `.git/modules/vendor/lib`. That is indistinguishable
// from a submodule inside a submodule by shape alone, which is why the
// watcher is pointed at the metadata directory and events are measured
// from there.
void test_git_metadata_dir_for_nested_path_submodule ()
{
	static std::string const git = scm::find_executable("git", "TM_GIT");
	if(git == NULL_STR)
		return;

	test::jail_t jail;
	std::string const lib   = path::join(jail.path(), "libsrc");
	std::string const super = path::join(jail.path(), "super");

	run_sh(text::format(
		"{ mkdir -p '%1$s' '%2$s' "
		"&& cd '%1$s' && '%3$s' init -b master "
		"&& '%3$s' config user.email 'test@example.com' && '%3$s' config user.name 'Test Test' "
		"&& '%3$s' config commit.gpgsign false "
		"&& printf 'lib\\n' > lib.txt && '%3$s' add lib.txt && '%3$s' commit -m lib "
		"&& cd '%2$s' && '%3$s' init -b master "
		"&& '%3$s' config user.email 'test@example.com' && '%3$s' config user.name 'Test Test' "
		"&& '%3$s' config commit.gpgsign false "
		"&& printf 'super\\n' > s.txt && '%3$s' add s.txt && '%3$s' commit -m super "
		"&& '%3$s' -c protocol.file.allow=always submodule add '%1$s' vendor/lib "
		"&& '%3$s' commit -m addsub "
		"; } >/dev/null 2>&1",
		lib.c_str(), super.c_str(), git.c_str()));

	std::string const sub = path::join(super, "vendor/lib");
	if(!path::exists(path::join(sub, ".git")))
		return; // submodules disabled in this environment

	// The name is the path, so the metadata directory is two components
	// deep under `modules/` — the case a shape-based classifier cannot
	// tell from `modules/a/modules/b`.
	std::string const meta = scm::git_metadata_dir(sub);
	OAK_ASSERT_EQ(meta, path::join(super, ".git/modules/vendor/lib"));
	OAK_ASSERT(path::relative_to(meta, sub).compare(0, 2, "..") == 0);

	// Measured from that directory, its own metadata classifies…
	OAK_ASSERT(scm::is_repo_meta_path(meta, meta));
	OAK_ASSERT(scm::is_repo_meta_path(meta, path::join(meta, "HEAD")));
	OAK_ASSERT(scm::is_repo_meta_path(meta, path::join(meta, "index")));
	OAK_ASSERT(scm::is_repo_meta_path(meta, path::join(meta, "refs/heads")));

	// …and its neighbours still do not.
	OAK_ASSERT(!scm::is_repo_meta_path(meta, path::join(meta, "objects")));
	OAK_ASSERT(!scm::is_repo_meta_path(meta, path::join(meta, "objects/ab")));
	OAK_ASSERT(!scm::is_repo_meta_path(meta, path::join(meta, "logs/HEAD")));

	// The superproject's own metadata is not this submodule's.
	OAK_ASSERT(!scm::is_repo_meta_path(meta, path::join(super, ".git/HEAD")));
}

// The event-space form of a path is what the watcher's callbacks report,
// and is what classification has to be measured in.
void test_fs_event_path_prefixes_the_mount_point ()
{
	test::jail_t jail;
	std::string const p = jail.path();
	std::string const e = scm::fs_event_path(p);

	// It never loses the path, and comparing a directory against its own
	// event form is the identity the classifier relies on.
	OAK_ASSERT(e.size() >= p.size());
	OAK_ASSERT(e == p || e.find(p) != std::string::npos);
	OAK_ASSERT(scm::is_repo_meta_path(e, e));

	// A path that does not exist is returned untouched rather than guessed at.
	std::string const missing = path::join(p, "no/such/place");
	OAK_ASSERT_EQ(scm::fs_event_path(missing), missing);
}
