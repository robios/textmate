#ifndef SCM_GIT_QUERY_H_QX41REVB
#define SCM_GIT_QUERY_H_QX41REVB

#include <string>
#include <vector>

// Small synchronous git queries for the git-native review surfaces
// (review-base selector, HEAD-moved banner, staged-state chip). Each
// call runs a git subprocess, so call from a background queue; results
// are not cached here — the caller decides the refresh cadence.
namespace scm { namespace git_query {

	// Full sha a revspec names, or NULL_STR when it names nothing — which
	// includes a spec reaching back past the first commit (`HEAD~1` in a
	// repo with one commit). Callers with a relative spec resolve it here
	// and pass the sha on, so nothing downstream is keyed by a ref whose
	// meaning moves.
	std::string rev_parse (std::string const& repo_root, std::string const& revspec);

	// Full sha of HEAD, or NULL_STR outside a repo / before the first commit.
	std::string head_commit (std::string const& repo_root);

	// True when `ancestor` is an ancestor of (or equal to) `descendant`.
	bool is_ancestor (std::string const& repo_root, std::string const& ancestor, std::string const& descendant);

	// Does the index differ from HEAD for this path?
	bool has_staged_changes (std::string const& repo_root, std::string const& rel_path);

	struct commit_t
	{
		std::string sha;     // full sha
		std::string subject; // first line of the commit message
	};

	// Newest-first commits reachable from HEAD, at most `limit`.
	std::vector<commit_t> recent_commits (std::string const& repo_root, size_t limit);

} /* git_query */ } /* scm */

#endif /* end of include guard: SCM_GIT_QUERY_H_QX41REVB */
