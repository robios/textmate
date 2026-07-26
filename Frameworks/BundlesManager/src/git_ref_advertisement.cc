#include "git_ref_advertisement.h"

namespace
{
	static int hex_value (char ch)
	{
		if(ch >= '0' && ch <= '9') return ch - '0';
		if(ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
		if(ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
		return -1;
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

namespace git
{
	bool is_sha (std::string const& str)
	{
		if(str.size() != 40)
			return false;
		for(char ch : str)
		{
			if(hex_value(ch) == -1)
				return false;
		}
		return true;
	}

	std::string ref_advertisement_t::default_branch () const
	{
		static std::string const kHeadsPrefix = "refs/heads/";
		if(head_symref.compare(0, kHeadsPrefix.size(), kHeadsPrefix) == 0)
			return head_symref.substr(kHeadsPrefix.size());
		return std::string();
	}

	std::string ref_advertisement_t::resolve (std::string const& ref) const
	{
		if(ref.empty())
			return std::string();

		// An exact revision needs no advertisement to be usable; ‘deadbeef’ does,
		// since expanding an abbreviation is not something the protocol offers.
		if(is_sha(ref))
			return lowercased(ref);

		// An annotated tag advertises both the tag object and, as ‘^{}’, the commit
		// it points at — the latter is what a checkout of that tag would produce.
		for(std::string candidate : { ref + "^{}", ref, "refs/heads/" + ref, "refs/tags/" + ref + "^{}", "refs/tags/" + ref })
		{
			auto it = refs.find(candidate);
			if(it != refs.end())
				return it->second;
		}

		return std::string();
	}

	ref_advertisement_t parse_ref_advertisement (char const* data, size_t len)
	{
		static std::string const kSymrefPrefix = "symref=HEAD:";

		ref_advertisement_t res;
		if(!data || len == 0)
			return res;

		bool sawCapabilities = false;
		size_t pos = 0;

		while(pos != len)
		{
			if(len - pos < 4)
				return ref_advertisement_t();

			size_t length = 0;
			for(size_t i = 0; i < 4; ++i)
			{
				int value = hex_value(data[pos + i]);
				if(value == -1)
					return ref_advertisement_t();
				length = length * 16 + value;
			}

			if(length == 0) // Flush packet
			{
				pos += 4;
				continue;
			}

			// 0001…0003 are delimiter packets from protocol v2, which we never ask for
			if(length < 4 || pos + length > len)
				return ref_advertisement_t();

			std::string line(data + pos + 4, length - 4);
			pos += length;

			while(!line.empty() && (line.back() == '\n' || line.back() == '\r'))
				line.pop_back();

			if(line.empty() || line[0] == '#') // ‘# service=git-upload-pack’
				continue;

			if(line.compare(0, 4, "ERR ") == 0)
				return ref_advertisement_t();

			// Capabilities follow the first ref, separated by NUL
			std::string::size_type nul = line.find('\0');
			if(nul != std::string::npos)
			{
				if(sawCapabilities)
					return ref_advertisement_t();
				sawCapabilities = true;

				std::string capabilities = line.substr(nul + 1);
				line.erase(nul);

				for(std::string::size_type from = 0; from < capabilities.size(); )
				{
					std::string::size_type to = capabilities.find(' ', from);
					std::string capability = capabilities.substr(from, to == std::string::npos ? to : to - from);
					if(capability.compare(0, kSymrefPrefix.size(), kSymrefPrefix) == 0)
						res.head_symref = capability.substr(kSymrefPrefix.size());
					if(to == std::string::npos)
						break;
					from = to + 1;
				}
			}

			std::string::size_type space = line.find(' ');
			if(space == std::string::npos)
				return ref_advertisement_t();

			std::string sha     = line.substr(0, space);
			std::string refName = line.substr(space + 1);
			if(!is_sha(sha) || refName.empty())
				return ref_advertisement_t();

			res.refs.emplace(refName, lowercased(sha));
		}

		res.valid = true;
		return res;
	}

} /* git */
