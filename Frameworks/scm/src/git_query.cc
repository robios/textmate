#include "git_query.h"

#include <io/exec.h>
#include <io/path.h>
#include <io/environment.h>
#include <oak/oak.h>
#include "drivers/api.h"

namespace scm { namespace git_query {

	namespace
	{
		std::string run_git (std::string const& root, std::initializer_list<std::string> args)
		{
			static std::string const git = scm::find_executable("git", "TM_GIT");
			if(git == NULL_STR)
				return NULL_STR;

			std::map<std::string, std::string> env = oak::basic_environment();
			env["GIT_WORK_TREE"] = root;
			env["GIT_DIR"]       = path::join(root, ".git");

			std::vector<char const*> argv;
			for(auto const& arg : args)
				argv.push_back(arg.c_str());

			switch(argv.size())
			{
				case 1:  return io::exec(env, git, argv[0], nullptr);
				case 2:  return io::exec(env, git, argv[0], argv[1], nullptr);
				case 3:  return io::exec(env, git, argv[0], argv[1], argv[2], nullptr);
				case 4:  return io::exec(env, git, argv[0], argv[1], argv[2], argv[3], nullptr);
				case 5:  return io::exec(env, git, argv[0], argv[1], argv[2], argv[3], argv[4], nullptr);
				case 6:  return io::exec(env, git, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], nullptr);
				default: return NULL_STR;
			}
		}

		std::string chomp (std::string s)
		{
			while(!s.empty() && (s.back() == '\n' || s.back() == '\r'))
				s.pop_back();
			return s;
		}
	}

	std::string rev_parse (std::string const& repo_root, std::string const& revspec)
	{
		// `^{commit}` so a spec naming a tag or a tree cannot come back as
		// something blob_for_ref would then fail to read. A spec that
		// reaches past the root commit exits non-zero, which io::exec
		// reports as NULL_STR — the caller's cue to fall back to HEAD.
		std::string out = run_git(repo_root, { "rev-parse", "--verify", "--quiet", revspec + "^{commit}" });
		return out == NULL_STR ? NULL_STR : chomp(out);
	}

	std::string head_commit (std::string const& repo_root)
	{
		return rev_parse(repo_root, "HEAD");
	}

	bool is_ancestor (std::string const& repo_root, std::string const& ancestor, std::string const& descendant)
	{
		// io::exec reports a non-zero exit as NULL_STR, which is exactly
		// merge-base’s yes/no signal.
		return run_git(repo_root, { "merge-base", "--is-ancestor", ancestor, descendant }) != NULL_STR;
	}

	std::string symbolic_head (std::string const& repo_root)
	{
		// Fails — and so reports NULL_STR — exactly when HEAD is detached.
		std::string out = run_git(repo_root, { "symbolic-ref", "--quiet", "HEAD" });
		return out == NULL_STR ? NULL_STR : chomp(out);
	}

	head_change classify_head_change (std::string const& old_branch, std::string const& old_sha, std::string const& new_branch, std::string const& new_sha, bool is_descendant)
	{
		if(old_sha == NULL_STR || new_sha == NULL_STR)
			return head_change::none; // nothing observed yet, or an unborn HEAD

		bool const branch_changed = old_branch != new_branch;
		if(!branch_changed && old_sha == new_sha)
			return head_change::none;

		// A switch is a switch even when the commit is unchanged, and even
		// when the new tip happens to descend from the old one.
		if(branch_changed)
			return head_change::switched;

		return is_descendant ? head_change::committed : head_change::rewritten;
	}

	bool has_staged_changes (std::string const& repo_root, std::string const& rel_path)
	{
		std::string out = run_git(repo_root, { "diff", "--cached", "--name-only", "--", rel_path });
		return out != NULL_STR && !chomp(out).empty();
	}

	std::vector<commit_t> recent_commits (std::string const& repo_root, size_t limit)
	{
		std::vector<commit_t> res;
		std::string const out = run_git(repo_root, { "log", "--pretty=format:%H\t%s", "-n", std::to_string(limit) });
		if(out == NULL_STR)
			return res;

		size_t pos = 0;
		while(pos < out.size())
		{
			size_t eol = out.find('\n', pos);
			if(eol == std::string::npos)
				eol = out.size();

			size_t const tab = out.find('\t', pos);
			if(tab != std::string::npos && tab < eol)
				res.push_back({ out.substr(pos, tab - pos), out.substr(tab + 1, eol - tab - 1) });

			pos = eol + 1;
		}
		return res;
	}

} /* git_query */ } /* scm */
