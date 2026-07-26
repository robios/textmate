#include "github_url.h"

namespace
{
	static bool is_safe_path_component (std::string const& str)
	{
		// A leading dot is what ‘.’ and ‘..’ have in common with ‘.git’: nothing
		// GitHub will answer for, and nothing we want in a path we build.
		if(str.empty() || str.front() == '.')
			return false;

		for(char ch : str)
		{
			bool ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.';
			if(!ok)
				return false;
		}
		return true;
	}

	static std::string trimmed (std::string str)
	{
		std::string::size_type from = str.find_first_not_of(" \t\r\n");
		if(from == std::string::npos)
			return std::string();
		std::string::size_type to = str.find_last_not_of(" \t\r\n");
		return str.substr(from, to - from + 1);
	}

	static std::string lowercased (std::string str)
	{
		for(char& ch : str)
		{
			if(ch >= 'A' && ch <= 'Z')
				ch += 'a' - 'A';
		}
		return str;
	}

} /* anonymous */

namespace github
{
	repository_t parse_url (std::string const& urlString)
	{
		repository_t res;

		std::string url = trimmed(urlString);
		if(url.empty())
			return res;

		// Everything after the path is display state in the URLs GitHub hands out (‘?tab=readme’, ‘#install’)
		url = url.substr(0, url.find_first_of("?#"));

		// Before anything counts the separators
		while(!url.empty() && url.back() == '/')
			url.pop_back();

		std::string::size_type schemeEnd = url.find("://");
		if(schemeEnd != std::string::npos)
		{
			if(lowercased(url.substr(0, schemeEnd)) != "https")
				return res;
			url.erase(0, schemeEnd + 3);
		}

		std::string::size_type authorityEnd = url.find('/');
		if(authorityEnd == std::string::npos)
			return res;

		// Since github.com is the only host that can be meant, naming it is
		// optional: ‘owner/repository’ says everything a full URL does.
		std::string path;

		// The exact match is also what refuses userinfo: neither ‘user@github.com’ nor
		// ‘github.com@evil.example’ — the shape that reads as github.com but resolves elsewhere — compares equal
		std::string authority = lowercased(url.substr(0, authorityEnd));
		if(authority == "github.com" || authority == "www.github.com")
		{
			path = url.substr(authorityEnd + 1);
		}
		else if(schemeEnd == std::string::npos && url.find('/', authorityEnd + 1) == std::string::npos)
		{
			path = url;
		}
		else
		{
			return res;
		}
		while(!path.empty() && path.back() == '/')
			path.pop_back();

		std::string::size_type slash = path.find('/');
		if(slash == std::string::npos || path.find('/', slash + 1) != std::string::npos)
			return res;

		std::string owner = path.substr(0, slash);
		std::string name  = path.substr(slash + 1);

		if(name.size() > 4 && name.compare(name.size() - 4, 4, ".git") == 0)
			name.erase(name.size() - 4);

		if(!is_safe_path_component(owner) || !is_safe_path_component(name))
			return res;

		res.owner = owner;
		res.name  = name;
		return res;
	}

	std::string parse_owner_url (std::string const& urlString)
	{
		std::string url = trimmed(urlString);
		url = url.substr(0, url.find_first_of("?#"));

		std::string::size_type schemeEnd = url.find("://");
		if(schemeEnd != std::string::npos)
		{
			if(lowercased(url.substr(0, schemeEnd)) != "https")
				return std::string();
			url.erase(0, schemeEnd + 3);
		}

		while(!url.empty() && url.back() == '/')
			url.pop_back();

		// A bare name is an owner, for the same reason ‘owner/repository’ is a
		// repository: there is only one host it could refer to.
		std::string::size_type authorityEnd = url.find('/');
		std::string owner = authorityEnd == std::string::npos ? url : url.substr(authorityEnd + 1);

		if(authorityEnd != std::string::npos)
		{
			std::string authority = lowercased(url.substr(0, authorityEnd));
			if(authority != "github.com" && authority != "www.github.com")
				return std::string();
		}
		else if(schemeEnd != std::string::npos)
		{
			return std::string(); // ‘https://owner’ is not a thing
		}

		if(owner.find('/') != std::string::npos || !is_safe_path_component(owner))
			return std::string();

		// ‘github.com’ typed on its own is the host, not somebody’s account
		std::string lowercasedOwner = lowercased(owner);
		if(lowercasedOwner == "github.com" || lowercasedOwner == "www.github.com")
			return std::string();

		return owner;
	}

	// E.g. ‘<https://api.github.com/…?page=2>; rel="next", <…?page=5>; rel="last"’
	std::string next_page_url (std::string const& linkHeader)
	{
		for(std::string::size_type from = 0; from < linkHeader.size(); )
		{
			std::string::size_type to = linkHeader.find(',', from);
			std::string link = linkHeader.substr(from, to == std::string::npos ? to : to - from);
			from = to == std::string::npos ? linkHeader.size() : to + 1;

			std::string::size_type open  = link.find('<');
			std::string::size_type close = link.find('>', open == std::string::npos ? 0 : open);
			if(open == std::string::npos || close == std::string::npos)
				continue;

			if(link.find("rel=\"next\"", close) != std::string::npos || link.find("rel=next", close) != std::string::npos)
				return trimmed(link.substr(open + 1, close - open - 1));
		}
		return std::string();
	}

	std::string repository_t::canonical_url () const
	{
		return "https://github.com/" + owner + "/" + name;
	}

	std::string repository_t::ref_advertisement_url () const
	{
		return canonical_url() + ".git/info/refs?service=git-upload-pack";
	}

	std::string repository_t::tarball_url (std::string const& sha) const
	{
		return "https://codeload.github.com/" + owner + "/" + name + "/tar.gz/" + sha;
	}

	std::string repository_t::raw_url (std::string const& sha, std::string const& path) const
	{
		return "https://raw.githubusercontent.com/" + owner + "/" + name + "/" + sha + "/" + path;
	}

	std::string repository_t::compare_url (std::string const& from, std::string const& to) const
	{
		return canonical_url() + "/compare/" + from + "..." + to;
	}

	std::string owner_repositories_url (std::string const& owner, bool isOrganization)
	{
		if(!is_safe_path_component(owner))
			return std::string();
		return std::string("https://api.github.com/") + (isOrganization ? "orgs/" : "users/") + owner + "/repos?per_page=100";
	}

} /* github */
