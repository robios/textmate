#include "markdown_render.h"

#include <cmark-gfm.h>
#include <cmark-gfm-extension_api.h>
#include <cmark-gfm-core-extensions.h>
#include <mutex>

namespace markdown
{
	std::string to_html (std::string const& markdown, bool sourcePositions)
	{
		// UNSAFE passes raw HTML through, mirroring GitHub’s pipeline where the
		// tagfilter extension then neuters the dangerous tags.
		int const options = CMARK_OPT_UNSAFE | (sourcePositions ? CMARK_OPT_SOURCEPOS : 0);

		// cmark-gfm is not thread-safe here: registration mutates a global
		// registry, and the registry hands every parser the same extension
		// objects, whose state concurrent parses corrupt (~25% bad output in an
		// 8-thread hammer test). Full-document renders are fast, so serializing
		// them is cheaper than managing per-parse extension instances.
		static std::mutex renderMutex;
		std::lock_guard<std::mutex> lock(renderMutex);

		cmark_gfm_core_extensions_ensure_registered();

		cmark_parser* parser = cmark_parser_new(options);
		for(char const* name : { "table", "strikethrough", "autolink", "tasklist", "tagfilter" })
		{
			if(cmark_syntax_extension* extension = cmark_find_syntax_extension(name))
				cmark_parser_attach_syntax_extension(parser, extension);
		}

		cmark_parser_feed(parser, markdown.data(), markdown.size());
		cmark_node* document = cmark_parser_finish(parser);

		char* html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser));
		std::string res = html ?: "";

		free(html);
		cmark_node_free(document);
		cmark_parser_free(parser);

		return res;
	}

} /* markdown */
