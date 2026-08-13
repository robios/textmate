#ifndef PREVIEW_CONVERTER_H_C7Q2MNRD
#define PREVIEW_CONVERTER_H_C7Q2MNRD

#include <bundles/bundles.h>

namespace preview
{
	enum class converter_kind_t { none, markdown, external };

	// The single source of truth for whether (and how) a document previews:
	// menu validation, pane targeting, and rendering all resolve through it.
	struct converter_t
	{
		converter_kind_t kind = converter_kind_t::none;
		std::string command   = NULL_STR;   // external only: the shell command
		bundles::item_ptr item;             // external only: the declaring settings item

		explicit operator bool () const { return kind != converter_kind_t::none; }

		bool operator== (converter_t const& rhs) const { return kind == rhs.kind && command == rhs.command && item == rhs.item; }
		bool operator!= (converter_t const& rhs) const { return !(*this == rhs); }
	};

	// Resolution order for a document’s fileType scope: a bundle-declared
	// ‘previewCommand’ setting wins (even for Markdown, so the built-in
	// renderer is a default rather than a special case), then the built-in
	// cmark path for text.html.markdown, then no preview.
	converter_t converter_for_file_type (std::string const& fileType);

	// The environment an external converter runs with: the given base plus
	// TM_DISPLAYNAME, TM_BUNDLE_SUPPORT (the declaring item’s bundle),
	// TM_PREVIEW=1, and — only for a saved document — TM_FILEPATH and
	// TM_DIRECTORY. Deliberately not the full command environment: a preview
	// converter is a pure document transform, so no selection or caret.
	std::map<std::string, std::string> converter_environment (std::map<std::string, std::string> base, std::string const& displayName, std::string const& path, bundles::item_ptr const& item);

} /* preview */

#endif /* end of include guard: PREVIEW_CONVERTER_H_C7Q2MNRD */
