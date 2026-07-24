#ifndef TERMINAL_LINK_DETECT_H_B7E4A912
#define TERMINAL_LINK_DETECT_H_B7E4A912

#include <string>

namespace terminal
{
	// A file reference found in one (logical) line of terminal output.
	struct file_link_t
	{
		size_t first = 0, last = 0; // byte range of the reference within the line (for underlining)
		std::string path;           // as written — may be relative or ~-prefixed
		std::string alt_path;       // fallback candidate (git-diff a/·b/ prefix stripped); empty if none
		size_t line = 0;            // 1-based, 0 = no line info
		size_t column = 0;          // 1-based, 0 = no column info
	};

	// Extract the file reference containing byte offset `offset`, if any.
	// Purely textual — the caller decides whether the path actually exists.
	// Recognized forms: path[:line[:col]] with optional trailing colon
	// (compiler diagnostics, grep -n), Python tracebacks (File "x.py", line 12),
	// git-diff a/…·b/… paths, and bare paths. Wrapping quotes/parentheses and
	// trailing punctuation are stripped; URLs (scheme://…) are rejected.
	bool link_at_offset (std::string const& line, size_t offset, file_link_t& out);

} /* terminal */

#endif /* TERMINAL_LINK_DETECT_H_B7E4A912 */
