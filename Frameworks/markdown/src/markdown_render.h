#ifndef MARKDOWN_RENDER_H_C4E2A7D1
#define MARKDOWN_RENDER_H_C4E2A7D1

#include <string>

namespace markdown
{
	// Render UTF-8 Markdown to an HTML fragment via cmark-gfm with the GFM
	// extensions (tables, strikethrough, autolink, task lists, tag filter).
	// TeX math ($…$ inline, block-position $$…$$ display) is masked from
	// cmark and comes back as data-tm-math elements (math_spans.h).
	// Source-position attributes (data-sourcepos) are on by default for the
	// live preview’s scroll sync; pass false for standalone HTML output.
	std::string to_html (std::string const& markdown, bool sourcePositions = true);

} /* markdown */

#endif /* MARKDOWN_RENDER_H_C4E2A7D1 */
