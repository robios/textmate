#include "../src/preview_converter.h"
#include <test/bundle_index.h>

using preview::converter_kind_t;

// The fixtures cover the three resolution outcomes: an external converter for
// a non-Markdown scope, the ‘external wins’ override for a Markdown scope, and
// the built-in fallback for plain Markdown. All preview fixtures live in this
// one setup: gen_test runs every setup before any test, and committing a
// bundle index replaces the whole index — a second setup would clobber this
// one. t_preview_pane.mm relies on the ‘source.pane-test’ item below.
void setup_preview_fixtures ()
{
	static std::string LaTeXPreview =
		"{	name     = 'LaTeX Preview';"
		"	scope    = 'text.tex.latex';"
		"	settings = { previewCommand = 'ruby \"$TM_BUNDLE_SUPPORT/bin/latex_preview.rb\"'; };"
		"}";

	static std::string MarkdownOverride =
		"{	name     = 'Custom Markdown Preview';"
		"	scope    = 'text.html.markdown.special';"
		"	settings = { previewCommand = 'custom-markdown'; };"
		"}";

	static std::string EmptyCommand =
		"{	name     = 'Empty Preview Command';"
		"	scope    = 'source.empty-preview';"
		"	settings = { previewCommand = ''; };"
		"}";

	// A minimal real converter — wraps the buffer in a sourcepos-carrying
	// <pre> — for the pane-level end-to-end test.
	static std::string PaneTestPreview =
		"{	name     = 'Pane Test Preview';"
		"	scope    = 'source.pane-test';"
		"	settings = { previewCommand = 'printf \"<pre data-sourcepos=1:1-1:1>\"; cat; printf \"</pre>\"'; };"
		"}";

	// The same converter, but paced by the test through files in the
	// document's own directory (which is the converter's cwd): it announces
	// its start, waits to be released, and marks the output as written. That
	// lets the pane test hold a render in flight across a document switch
	// without timing anything.
	static std::string GatedPaneTestPreview =
		"{	name     = 'Gated Pane Test Preview';"
		"	scope    = 'source.pane-test-gated';"
		"	settings = { previewCommand = ': > preview-started; while [ ! -f preview-go ]; do sleep 0.05; done; printf \"<pre data-sourcepos=1:1-1:1>\"; cat; printf \"</pre>\"; : > preview-done'; };"
		"}";

	// A converter that leaks a SIGTERM-proof background job into its process
	// group and then exits normally, recording the job’s pid in the document’s
	// directory. Nothing but the run itself is left to clean the group up.
	static std::string OrphanPaneTestPreview =
		"{	name     = 'Orphaning Pane Test Preview';"
		"	scope    = 'source.pane-test-orphan';"
		"	settings = { previewCommand = '{ trap \"\" TERM; exec sleep 30; } >/dev/null 2>&1 & echo $! > preview-child.pid; printf \"<pre data-sourcepos=1:1-1:1>\"; cat; printf \"</pre>\"'; };"
		"}";

	test::bundle_index_t bundleIndex;
	bundleIndex.add(bundles::kItemTypeSettings, LaTeXPreview);
	bundleIndex.add(bundles::kItemTypeSettings, MarkdownOverride);
	bundleIndex.add(bundles::kItemTypeSettings, EmptyCommand);
	bundleIndex.add(bundles::kItemTypeSettings, PaneTestPreview);
	bundleIndex.add(bundles::kItemTypeSettings, GatedPaneTestPreview);
	bundleIndex.add(bundles::kItemTypeSettings, OrphanPaneTestPreview);
	bundleIndex.commit();
}

void test_external_converter ()
{
	preview::converter_t const converter = preview::converter_for_file_type("text.tex.latex");
	OAK_ASSERT(converter.kind == converter_kind_t::external);
	OAK_ASSERT_EQ(converter.command, "ruby \"$TM_BUNDLE_SUPPORT/bin/latex_preview.rb\"");
	OAK_ASSERT(converter.item ? true : false);
	OAK_ASSERT(bool(converter));
}

void test_builtin_markdown ()
{
	OAK_ASSERT(preview::converter_for_file_type("text.html.markdown").kind == converter_kind_t::markdown);
	OAK_ASSERT(preview::converter_for_file_type("text.html.markdown.gfm").kind == converter_kind_t::markdown);
}

void test_external_wins_over_markdown ()
{
	preview::converter_t const converter = preview::converter_for_file_type("text.html.markdown.special");
	OAK_ASSERT(converter.kind == converter_kind_t::external);
	OAK_ASSERT_EQ(converter.command, "custom-markdown");
}

void test_no_converter ()
{
	OAK_ASSERT(preview::converter_for_file_type("source.c").kind == converter_kind_t::none);
	OAK_ASSERT(preview::converter_for_file_type("text.plain").kind == converter_kind_t::none);
	OAK_ASSERT(preview::converter_for_file_type(NULL_STR).kind == converter_kind_t::none);
	OAK_ASSERT(preview::converter_for_file_type("").kind == converter_kind_t::none);
	OAK_ASSERT(!preview::converter_for_file_type("source.c"));

	// A declared-but-empty command is no converter — and must not fall back to
	// the built-in path for a non-Markdown scope.
	OAK_ASSERT(preview::converter_for_file_type("source.empty-preview").kind == converter_kind_t::none);
}

void test_converter_environment ()
{
	std::map<std::string, std::string> const base = { { "PATH", "/usr/bin" } };

	auto env = preview::converter_environment(base, "test.tex", "/tmp/dir/test.tex", bundles::item_ptr());
	OAK_ASSERT_EQ(env["PATH"], "/usr/bin");
	OAK_ASSERT_EQ(env["TM_DISPLAYNAME"], "test.tex");
	OAK_ASSERT_EQ(env["TM_FILEPATH"], "/tmp/dir/test.tex");
	OAK_ASSERT_EQ(env["TM_DIRECTORY"], "/tmp/dir");
	OAK_ASSERT_EQ(env["TM_PREVIEW"], "1");
	OAK_ASSERT_EQ(env.count("TM_SELECTION"), 0);

	// Unsaved document: no file, no directory
	env = preview::converter_environment(base, "untitled", NULL_STR, bundles::item_ptr());
	OAK_ASSERT_EQ(env.count("TM_FILEPATH"), 0);
	OAK_ASSERT_EQ(env.count("TM_DIRECTORY"), 0);
	OAK_ASSERT_EQ(env["TM_PREVIEW"], "1");
}
