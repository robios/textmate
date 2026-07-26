#ifndef GIT_REF_ADVERTISEMENT_H_7DPQ2ZLA
#define GIT_REF_ADVERTISEMENT_H_7DPQ2ZLA

#include <map>
#include <string>

namespace git
{
	bool is_sha (std::string const& str); // Exactly 40 hexadecimal characters

	// The reply to ‘…/info/refs?service=git-upload-pack’: pkt-line framed
	// ‘<sha> <refname>’ records. We read it rather than api.github.com because
	// the git protocol is not rate limited and polling many subscriptions
	// against a 60 requests/hour REST quota is not viable.
	struct ref_advertisement_t
	{
		bool valid = false;
		std::string head_symref;                 // E.g. ‘refs/heads/main’, empty when HEAD advertises no symref
		std::map<std::string, std::string> refs; // Refname → SHA; peeled tags keep their ‘^{}’ suffix

		explicit operator bool () const { return valid; }

		std::string default_branch () const;                // ‘main’ for a HEAD symref of ‘refs/heads/main’
		std::string resolve (std::string const& ref) const; // Empty when the ref is not advertised
	};

	ref_advertisement_t parse_ref_advertisement (char const* data, size_t len);
	inline ref_advertisement_t parse_ref_advertisement (std::string const& str) { return parse_ref_advertisement(str.data(), str.size()); }

} /* git */

#endif /* end of include guard: GIT_REF_ADVERTISEMENT_H_7DPQ2ZLA */
