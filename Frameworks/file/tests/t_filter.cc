#include <file/filter.h>
#include <bundles/bundles.h>

// A runLocation:terminal command is not a filter candidate — it has no way to
// take a document on stdin or hand the converted content back. What these tests
// pin down is that it is not a candidate *early enough*: bundles::query keeps
// only the highest-ranked scope matches, so rejecting it after that call would
// let the narrowly-scoped terminal command below carry the cutoff away and hide
// the broadly-scoped filter that should be chosen. See t_bundle_fixtures.cc for
// the two pairs.

static std::vector<std::string> filter_names (std::string const& event, std::string const& pathAttributes, std::string const& content = "")
{
	std::vector<std::string> res;
	for(auto const& item : filter::find("/tmp/does-not-matter", std::make_shared<io::bytes_t>(content), pathAttributes, event))
		res.push_back(item->name());
	return res;
}

void test_terminal_command_does_not_hide_a_filter ()
{
	auto const names = filter_names(filter::kBundleEventTextImport, "attr.test.filter-ordering.specific");
	OAK_ASSERT_EQ(names.size(), 1);
	OAK_ASSERT_EQ(names[0], "In Process Import Filter");
}

void test_terminal_command_does_not_hide_a_binary_filter ()
{
	auto const names = filter_names(filter::kBundleEventBinaryImport, "attr.test.filter-ordering.specific", "FILTERTEST payload");
	OAK_ASSERT_EQ(names.size(), 1);
	OAK_ASSERT_EQ(names[0], "In Process Binary Import Filter");
}

// Without the more specific terminal command in play, the ordinary filter is
// found the same way — i.e. the tests above are not passing by accident.
void test_filter_without_a_competing_terminal_command ()
{
	auto const names = filter_names(filter::kBundleEventTextImport, "attr.test.filter-ordering");
	OAK_ASSERT_EQ(names.size(), 1);
	OAK_ASSERT_EQ(names[0], "In Process Import Filter");
}

void test_no_filter_outside_the_scope ()
{
	OAK_ASSERT_EQ(filter_names(filter::kBundleEventTextImport, "attr.test.unrelated").size(), 0);
}
