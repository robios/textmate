#ifndef AGENT_QUOTE_H_T3XN82VK
#define AGENT_QUOTE_H_T3XN82VK

#include <string>

// Codex is registered through launch-time -c overrides, whose values are TOML
// fragments carried inside shell words: the path to tm_agent therefore travels
// through two escapes on its way to a command line. Getting either wrong is
// how a path with a space silently registers the wrong command — or worse,
// runs part of it — so both live here, pure and tested.
namespace agent_quote
{
	// A TOML basic string.
	inline std::string toml (std::string const& value)
	{
		std::string res = "\"";
		for(char const ch : value)
		{
			if(ch == '\\' || ch == '"')
				res += '\\';
			res += ch;
		}
		return res + "\"";
	}

	// One shell word, quoted only when it needs to be: the command line is
	// typed into a visible terminal session the user can read and edit, and
	// quoting a bare ‘codex’ would only make it harder to read.
	inline std::string shell (std::string const& value)
	{
		auto is_safe = [](char ch){
			return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' || ch == '.' || ch == '/';
		};

		bool safe = !value.empty();
		for(char const ch : value)
			safe = safe && is_safe(ch);
		if(safe)
			return value;

		// Single quotes protect everything but a single quote, which has to
		// leave the quoted run to be escaped and come straight back in.
		std::string res = "'";
		for(char const ch : value)
		{
			if(ch == '\'')
					res += "'\\''";
			else	res += ch;
		}
		return res + "'";
	}

} /* agent_quote */

#endif /* AGENT_QUOTE_H_T3XN82VK */
