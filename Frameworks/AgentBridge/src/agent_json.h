#ifndef AGENT_JSON_H_R7VQ2XLD
#define AGENT_JSON_H_R7VQ2XLD

#import <nlohmann/json.hpp>
#import <ns/ns.h>
#import <Foundation/Foundation.h>

// Small JSON helpers shared by the two MCP frontends inside TextMate: the
// WebSocket server and the tool implementations it and the mate-socket seam
// both call. Kept in one place so the wire shapes cannot drift between them.
namespace agent_json
{
	inline constexpr size_t maximum_selection_bytes = 64 * 1024;

	// Serialize without throwing: tool results may contain buffer excerpts
	// whose range boundaries split a multi-byte character, and dump()’s default
	// strict handler throws type_error.316 on invalid UTF-8.
	inline std::string dump (nlohmann::json const& payload)
	{
		return payload.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
	}

	inline std::string string_arg (nlohmann::json const& args, char const* key, std::string const& fallback = "")
	{
		auto it = args.find(key);
		return it != args.end() && it->is_string() ? it->get<std::string>() : fallback;
	}

	inline bool bool_arg (nlohmann::json const& args, char const* key, bool fallback)
	{
		auto it = args.find(key);
		return it != args.end() && it->is_boolean() ? it->get<bool>() : fallback;
	}

	inline std::string file_uri (NSString* path)
	{
		// Percent-encoded like every other IDE client; isDirectory:NO both
		// avoids a stat() and matches the convention of no trailing slash on
		// folder URIs.
		return to_s([NSURL fileURLWithPath:path isDirectory:NO].absoluteString);
	}

	// Cut at a UTF-8 character boundary, so a capped excerpt is still text.
	inline std::string truncate_utf8 (std::string const& text, size_t limit)
	{
		if(text.size() <= limit)
			return text;

		size_t to = limit;
		while(to > 0 && (text[to] & 0xC0) == 0x80) // back off over continuation bytes
			--to;
		return text.substr(0, to);
	}

} /* agent_json */

#endif /* AGENT_JSON_H_R7VQ2XLD */
