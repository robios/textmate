#ifndef GITHUB_URL_H_QJ3XW08M
#define GITHUB_URL_H_QJ3XW08M

#include <string>

namespace github
{
	// A validated github.com repository. There is deliberately no way to
	// construct one that points elsewhere: subscriptions have no signature, so
	// the host allow-list is part of what stands in for one.
	struct repository_t
	{
		std::string owner;
		std::string name;

		explicit operator bool () const           { return !owner.empty() && !name.empty(); }
		bool operator== (repository_t const& rhs) const { return owner == rhs.owner && name == rhs.name; }
		bool operator!= (repository_t const& rhs) const { return !(*this == rhs); }

		std::string canonical_url () const;
		std::string ref_advertisement_url () const;
		std::string tarball_url (std::string const& sha) const;
		std::string raw_url (std::string const& sha, std::string const& path) const;
		std::string compare_url (std::string const& from, std::string const& to) const;
	};

	// Returns a falsy repository for anything that is not a github.com
	// repository URL. A missing scheme is assumed to be https.
	repository_t parse_url (std::string const& url);

	// ‘https://github.com/textmate’ — an owner without a repository, which is a
	// request to enumerate rather than a malformed repository URL.
	std::string parse_owner_url (std::string const& url);

	std::string owner_repositories_url (std::string const& owner, bool isOrganization);

	// The ‘Link’ header is how the REST API paginates; following it is what
	// keeps enumeration from silently stopping at the first hundred.
	std::string next_page_url (std::string const& linkHeader);

} /* github */

#endif /* end of include guard: GITHUB_URL_H_QJ3XW08M */
