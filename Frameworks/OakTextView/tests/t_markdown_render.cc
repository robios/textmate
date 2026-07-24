#include <OakTextView/markdown_render.h>

void test_basic_paragraph ()
{
	std::string const html = markdown::to_html("Hello *world*\n");
	OAK_ASSERT(html.find("<p") != std::string::npos);
	OAK_ASSERT(html.find("<em>world</em>") != std::string::npos);
}

void test_sourcepos_attributes ()
{
	std::string const html = markdown::to_html("first\n\nsecond\n");
	OAK_ASSERT(html.find("data-sourcepos=\"1:1-1:5\"") != std::string::npos);
	OAK_ASSERT(html.find("data-sourcepos=\"3:1-3:6\"") != std::string::npos);
}

void test_gfm_table ()
{
	std::string const html = markdown::to_html("| a | b |\n|---|---|\n| 1 | 2 |\n");
	OAK_ASSERT(html.find("<table") != std::string::npos);
	OAK_ASSERT(html.find(">1</td>") != std::string::npos); // <td> carries a data-sourcepos attribute
}

void test_gfm_strikethrough ()
{
	std::string const html = markdown::to_html("~~gone~~\n");
	OAK_ASSERT(html.find("<del>gone</del>") != std::string::npos);
}

void test_gfm_autolink ()
{
	std::string const html = markdown::to_html("visit https://macromates.com now\n");
	OAK_ASSERT(html.find("<a href=\"https://macromates.com\"") != std::string::npos);
}

void test_gfm_tasklist ()
{
	std::string const html = markdown::to_html("- [x] done\n- [ ] todo\n");
	OAK_ASSERT(html.find("type=\"checkbox\"") != std::string::npos);
	OAK_ASSERT(html.find("checked") != std::string::npos);
}

void test_fenced_code_block ()
{
	std::string const html = markdown::to_html("```c\nint main ();\n```\n");
	OAK_ASSERT(html.find("<pre") != std::string::npos);
	OAK_ASSERT(html.find("language-c") != std::string::npos);
	OAK_ASSERT(html.find("int main ();") != std::string::npos);
}

void test_raw_html_and_tagfilter ()
{
	std::string const html = markdown::to_html("keep <b>bold</b> but filter <script>alert(1)</script>\n");
	OAK_ASSERT(html.find("<b>bold</b>") != std::string::npos);
	OAK_ASSERT(html.find("<script>") == std::string::npos);   // tagfilter escapes it
	OAK_ASSERT(html.find("&lt;script") != std::string::npos);
}

void test_relative_image ()
{
	std::string const html = markdown::to_html("![shot](images/shot.png)\n");
	OAK_ASSERT(html.find("<img src=\"images/shot.png\"") != std::string::npos);
}

void test_empty_input ()
{
	OAK_ASSERT_EQ(markdown::to_html(""), "");
}

void test_utf8_content ()
{
	std::string const html = markdown::to_html("# 日本語の見出し\n");
	OAK_ASSERT(html.find("日本語の見出し") != std::string::npos);
}
