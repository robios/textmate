#ifndef MARKDOWN_RENDER_H_C4E2A7D1
#define MARKDOWN_RENDER_H_C4E2A7D1

#include <string>

namespace markdown
{
	// Render UTF-8 Markdown to an HTML fragment via cmark-gfm with the GFM
	// extensions (tables, strikethrough, autolink, task lists, tag filter)
	// and source-position attributes (data-sourcepos) enabled.
	std::string to_html (std::string const& markdown);

} /* markdown */

#endif /* MARKDOWN_RENDER_H_C4E2A7D1 */
