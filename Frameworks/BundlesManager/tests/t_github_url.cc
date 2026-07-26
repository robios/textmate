#include <BundlesManager/github_url.h>

// Subscriptions carry no signature, so the host allow-list is load-bearing: it
// is the difference between “code from a repository you added” and “code from
// wherever the string pointed”.

void test_accepted_urls ()
{
	// github.com is the only host that can be meant, so naming it is optional:
	// the short form is what a user would type from memory.
	for(std::string url : { "https://github.com/robios/tm-bundles", "https://github.com/robios/tm-bundles.git", "https://github.com/robios/tm-bundles/", "https://www.github.com/robios/tm-bundles", "github.com/robios/tm-bundles", "https://GitHub.com/robios/tm-bundles", "  https://github.com/robios/tm-bundles  ", "https://github.com/robios/tm-bundles?tab=readme-ov-file", "robios/tm-bundles", "robios/tm-bundles.git", "robios/tm-bundles/" })
	{
		github::repository_t repo = github::parse_url(url);
		OAK_ASSERT_EQ((bool)repo, true);
		OAK_ASSERT_EQ(repo.owner, "robios");
		OAK_ASSERT_EQ(repo.name, "tm-bundles");
	}
}

void test_rejected_urls ()
{
	for(std::string url : {
		"",
		"https://gitlab.com/robios/tm-bundles",             // Another host
		"https://github.com.evil.example/robios/bundles",   // Host that merely starts the right way
		"https://evil.example/github.com/robios/bundles",
		"https://github.com@evil.example/robios/bundles",   // Userinfo that reads as github.com
		"https://user@github.com/robios/bundles",
		"http://github.com/robios/tm-bundles",              // Plain HTTP
		"file:///etc/passwd",
		"https://github.com/robios",                        // Owner without a repository
		"robios",                                           // …and its short form
		"gitlab.com/robios/tm-bundles",                     // Another host, spelled short
		"a/b/c",
		"https://github.com/robios/tm-bundles/tree/main",   // More than a repository
		"https://github.com/../../etc/passwd",
		"https://github.com/robios/..",
		"https://github.com/robios/tm bundles",
		"https://github.com/robios/.git",                   // Nothing GitHub answers for
		"https://github.com/.robios/bundles",
		"https://raw.githubusercontent.com/robios/tm-bundles/main/Taps/bundles.plist",
	})
	{
		OAK_ASSERT_EQ((bool)github::parse_url(url), false);
	}
}

void test_derived_urls ()
{
	github::repository_t repo = github::parse_url("https://github.com/robios/tm-bundles.git");

	OAK_ASSERT_EQ(repo.canonical_url(),          "https://github.com/robios/tm-bundles");
	OAK_ASSERT_EQ(repo.ref_advertisement_url(),  "https://github.com/robios/tm-bundles.git/info/refs?service=git-upload-pack");
	OAK_ASSERT_EQ(repo.tarball_url("abc123"),    "https://codeload.github.com/robios/tm-bundles/tar.gz/abc123");
	OAK_ASSERT_EQ(repo.raw_url("abc123", "Taps/bundles.plist"), "https://raw.githubusercontent.com/robios/tm-bundles/abc123/Taps/bundles.plist");
	OAK_ASSERT_EQ(repo.compare_url("old", "new"), "https://github.com/robios/tm-bundles/compare/old...new");
}

void test_canonical_url_is_the_identity_used_for_matching ()
{
	// A catalogue may publish either spelling; §9.2 treats a changed repository
	// URL as a source switch, so the two must not look like a change.
	OAK_ASSERT_EQ(github::parse_url("https://github.com/robios/tm-bundles.git").canonical_url(), github::parse_url("github.com/robios/tm-bundles/").canonical_url());
	OAK_ASSERT_EQ(github::parse_url("https://github.com/robios/tm-bundles") == github::parse_url("https://www.github.com/robios/tm-bundles"), true);
	OAK_ASSERT_EQ(github::parse_url("https://github.com/robios/a") != github::parse_url("https://github.com/robios/b"), true);
}

void test_owner_enumeration_url ()
{
	OAK_ASSERT_EQ(github::owner_repositories_url("textmatelives", true),  "https://api.github.com/orgs/textmatelives/repos?per_page=100");
	OAK_ASSERT_EQ(github::owner_repositories_url("robios", false),        "https://api.github.com/users/robios/repos?per_page=100");
	OAK_ASSERT_EQ(github::owner_repositories_url("../textmate", true),    "");
}

void test_owner_urls_are_told_apart_from_repository_urls ()
{
	OAK_ASSERT_EQ(github::parse_owner_url("https://github.com/textmate"),  "textmate");
	OAK_ASSERT_EQ(github::parse_owner_url("https://github.com/textmate/"), "textmate");
	OAK_ASSERT_EQ(github::parse_owner_url("github.com/textmate"),          "textmate");
	OAK_ASSERT_EQ(github::parse_owner_url("textmate"),                     "textmate");

	// A repository URL is not an enumeration request, and neither is anything
	// that would not be safe as a path component.
	OAK_ASSERT_EQ(github::parse_owner_url("https://github.com/textmate/ruby.tmbundle"), "");
	OAK_ASSERT_EQ(github::parse_owner_url("textmate/ruby.tmbundle"),                    "");
	OAK_ASSERT_EQ(github::parse_owner_url("https://textmate"),                          "");
	OAK_ASSERT_EQ(github::parse_owner_url("https://gitlab.com/textmate"),               "");
	OAK_ASSERT_EQ(github::parse_owner_url("https://github.com/.."),                     "");
	OAK_ASSERT_EQ(github::parse_owner_url("https://github.com"),                        "");

	// The host typed on its own is not somebody’s account
	OAK_ASSERT_EQ(github::parse_owner_url("github.com"),     "");
	OAK_ASSERT_EQ(github::parse_owner_url("www.github.com"), "");
	OAK_ASSERT_EQ(github::parse_owner_url("GitHub.com"),     "");
}

void test_pagination_follows_the_link_header ()
{
	// Enumeration that stopped at the first page would silently under-report an
	// owner with more than a hundred repositories.
	OAK_ASSERT_EQ(github::next_page_url("<https://api.github.com/user/1/repos?page=2>; rel=\"next\", <https://api.github.com/user/1/repos?page=5>; rel=\"last\""), "https://api.github.com/user/1/repos?page=2");
	OAK_ASSERT_EQ(github::next_page_url("<https://api.github.com/user/1/repos?page=4>; rel=\"prev\", <https://api.github.com/user/1/repos?page=1>; rel=\"first\""), "");
	OAK_ASSERT_EQ(github::next_page_url(""), "");
	OAK_ASSERT_EQ(github::next_page_url("garbage"), "");
}
