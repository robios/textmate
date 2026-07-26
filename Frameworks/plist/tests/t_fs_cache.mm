#include <plist/fs_cache.h>
#include <io/path.h>
#include <test/jail.h>

// A bundles directory is scanned through the cache, and anything the user can
// put in one has to survive that scan — including the symlink that points at
// itself, which is a single mistyped ‘ln -s’ away and used to take the whole
// application down with it. The bundle index is built at launch, so a crash
// here is a crash before the first window.

static void CreateBundle (std::string const& path, std::string const& uuid)
{
	path::make_dir(path);
	path::set_content(path::join(path, "info.plist"),
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
		"<plist version=\"1.0\"><dict>"
		"<key>name</key><string>Test</string>"
		"<key>uuid</key><string>" + uuid + "</string>"
		"</dict></plist>\n");
}

void test_a_link_to_itself_is_not_followed_forever ()
{
	test::jail_t jail;

	std::string const bundles = jail.path("Bundles");
	path::make_dir(bundles);

	CreateBundle(path::join(bundles, "Real.tmbundle"), "F5351E61-488E-44A5-BF0B-02FED526B641");
	path::link("Real.tmbundle", path::join(bundles, "Linked.tmbundle"));      // A link that leads somewhere
	path::link("Loop.tmbundle", path::join(bundles, "Loop.tmbundle"));        // …and one that leads to itself

	plist::cache_t cache;
	std::vector<std::string> entries = cache.entries(bundles, "*.tmbundle");
	OAK_ASSERT_EQ(entries.size(), 3);

	// The real one and the link to it both answer with the bundle; the loop
	// answers with nothing, which is what it is.
	OAK_ASSERT_EQ(cache.entries(path::join(bundles, "Real.tmbundle"), "*.plist").size(), 1);
	OAK_ASSERT_EQ(cache.entries(path::join(bundles, "Linked.tmbundle"), "*.plist").size(), 1);
	OAK_ASSERT_EQ(cache.entries(path::join(bundles, "Loop.tmbundle"), "*.plist").size(), 0);

	OAK_ASSERT_EQ(cache.content(path::join(bundles, "Linked.tmbundle/info.plist")).empty(), false);
	OAK_ASSERT_EQ(cache.content(path::join(bundles, "Loop.tmbundle/info.plist")).empty(), true);
}

void test_two_links_pointing_at_each_other_are_not_followed_forever ()
{
	test::jail_t jail;

	std::string const bundles = jail.path("Bundles");
	path::make_dir(bundles);

	path::link("Pong.tmbundle", path::join(bundles, "Ping.tmbundle"));
	path::link("Ping.tmbundle", path::join(bundles, "Pong.tmbundle"));

	plist::cache_t cache;
	OAK_ASSERT_EQ(cache.entries(bundles, "*.tmbundle").size(), 2);
	OAK_ASSERT_EQ(cache.entries(path::join(bundles, "Ping.tmbundle"), "*.plist").size(), 0);
	OAK_ASSERT_EQ(cache.entries(path::join(bundles, "Pong.tmbundle"), "*.plist").size(), 0);
}

void test_the_watch_list_ends_at_a_link_that_leads_back ()
{
	test::jail_t jail;

	std::string const bundles = jail.path("Bundles");
	path::make_dir(bundles);

	CreateBundle(path::join(bundles, "Real.tmbundle"), "F5351E61-488E-44A5-BF0B-02FED526B641");
	path::link("Real.tmbundle", path::join(bundles, "Linked.tmbundle"));
	path::link("Loop.tmbundle", path::join(bundles, "Loop.tmbundle"));

	// What the index build does before it asks for the watch list: read the
	// directory, then look inside each bundle it found.
	plist::cache_t cache;
	for(auto const& bundle : cache.entries(bundles, "*.tmbundle"))
		cache.entries(bundle, "*.plist");

	// The watch list follows links too — the whole point is to notice edits at
	// the other end — so it needs the same ceiling.
	std::set<std::string> heads;
	cache.copy_heads_for_path(bundles, std::inserter(heads, heads.end()));

	OAK_ASSERT_EQ(heads.find(bundles) != heads.end(), true);
	OAK_ASSERT_EQ(heads.find(path::join(bundles, "Real.tmbundle")) != heads.end(), true);
}

void test_cleanup_does_not_walk_a_link_that_leads_back ()
{
	test::jail_t jail;

	std::string const bundles = jail.path("Bundles");
	path::make_dir(bundles);

	CreateBundle(path::join(bundles, "Real.tmbundle"), "F5351E61-488E-44A5-BF0B-02FED526B641");
	path::link("Loop.tmbundle", path::join(bundles, "Loop.tmbundle"));

	plist::cache_t cache;
	for(auto const& bundle : cache.entries(bundles, "*.tmbundle"))
		cache.entries(bundle, "*.plist");

	// cleanup() decides what to keep by walking everything reachable from the
	// roots — links included — and runs when the index is saved, which is to
	// say at quit as well as after every change.
	cache.cleanup(std::vector<std::string>{ bundles });
	OAK_ASSERT_EQ(cache.entries(path::join(bundles, "Real.tmbundle"), "*.plist").size(), 1);
}
