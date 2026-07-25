#import "../src/agent_diagnostics.h"

// getDiagnostics answers out of a process-wide cache with a bounded result.
// Both halves of that — which files are in scope, and how much of them fits —
// are pure decisions, and both were wrong once: the answer used to carry a
// second window’s repository, and it used to grow with the number of files
// even after the diagnostics budget was spent.

static std::vector<agent_diagnostics::file_t> Files (std::vector<std::pair<std::string, size_t>> const& spec)
{
	std::vector<agent_diagnostics::file_t> res;
	for(auto const& pair : spec)
		res.push_back({ "file://" + pair.first, pair.first, pair.second });
	return res;
}

void test_scope_to_a_project ()
{
	auto const files = Files({
		{ "/tmp/repoA/main.cc",        3 },
		{ "/tmp/repoA/lib/util.cc",    1 },
		{ "/tmp/repoB/other.cc",       7 },
		{ "/tmp/repoA-sibling/x.cc",   2 }, // a prefix match that is NOT inside repoA
	});

	auto const scoped = agent_diagnostics::in_scope(files, "/tmp/repoA");
	OAK_ASSERT_EQ(scoped.size(), 2);
	OAK_ASSERT_EQ(scoped[0].path, "/tmp/repoA/lib/util.cc"); // by uri, not by input order
	OAK_ASSERT_EQ(scoped[1].path, "/tmp/repoA/main.cc");

	// No routing path means no scoping — the behaviour Claude has always had.
	OAK_ASSERT_EQ(agent_diagnostics::in_scope(files, "").size(), files.size());

	// A trailing slash on the root must not change the answer, and the root
	// itself is inside itself.
	OAK_ASSERT_EQ(agent_diagnostics::in_scope(files, "/tmp/repoA/").size(), 2);
	OAK_ASSERT(agent_diagnostics::within("/tmp/repoA", "/tmp/repoA"));
	OAK_ASSERT(!agent_diagnostics::within("/tmp/repoA-sibling/x.cc", "/tmp/repoA"));
	OAK_ASSERT(!agent_diagnostics::within("/tmp/repo", "/tmp/repoA"));
}

void test_scoping_orders_the_result ()
{
	// The caller enumerates a dictionary, so the input order is whatever the
	// hash gave. Once a file cap exists, that decides *which* files survive —
	// two identical calls must not answer with different ones.
	auto const forward  = agent_diagnostics::in_scope(Files({ { "/p/a.cc", 1 }, { "/p/b.cc", 1 }, { "/p/c.cc", 1 } }), "");
	auto const backward = agent_diagnostics::in_scope(Files({ { "/p/c.cc", 1 }, { "/p/a.cc", 1 }, { "/p/b.cc", 1 } }), "");

	OAK_ASSERT_EQ(forward.size(), backward.size());
	for(size_t i = 0; i < forward.size(); ++i)
		OAK_ASSERT_EQ(forward[i].uri, backward[i].uri);
	OAK_ASSERT_EQ(forward[0].path, "/p/a.cc");
	OAK_ASSERT_EQ(forward[2].path, "/p/c.cc");
}

void test_budget_stops_at_the_diagnostic_cap ()
{
	auto const files = Files({ { "/p/a.cc", 120 }, { "/p/b.cc", 120 }, { "/p/c.cc", 120 } });
	auto const plan  = agent_diagnostics::plan(files, 200, 50);

	OAK_ASSERT_EQ(plan.entries.size(), 2);
	OAK_ASSERT_EQ(plan.entries[0].take, 120);
	OAK_ASSERT_EQ(plan.entries[0].omitted, 0);
	OAK_ASSERT_EQ(plan.entries[1].take, 80);     // the cap lands mid-file
	OAK_ASSERT_EQ(plan.entries[1].omitted, 40);  // and that file says how much it lost

	OAK_ASSERT_EQ(plan.omitted_files, 1);
	OAK_ASSERT_EQ(plan.omitted_diagnostics, 120);
}

void test_response_does_not_grow_with_the_number_of_files ()
{
	// The regression this exists for: the diagnostic budget was spent by the
	// first file, and every one of the remaining thousands was still listed —
	// an envelope each, unbounded in exactly the way the cap forbids.
	std::vector<std::pair<std::string, size_t>> spec = { { "/p/first.cc", 200 } };
	for(size_t i = 0; i < 5000; ++i)
		spec.push_back({ "/p/generated-" + std::to_string(i) + ".cc", 1 });

	auto const plan = agent_diagnostics::plan(Files(spec), 200, 50);

	OAK_ASSERT_EQ(plan.entries.size(), 1);
	OAK_ASSERT_EQ(plan.entries[0].take, 200);
	OAK_ASSERT_EQ(plan.omitted_files, 5000);
	OAK_ASSERT_EQ(plan.omitted_diagnostics, 5000);
}

void test_budget_stops_at_the_file_cap ()
{
	// Plenty of budget for the diagnostics; far too many files to list.
	std::vector<std::pair<std::string, size_t>> spec;
	for(size_t i = 0; i < 400; ++i)
		spec.push_back({ "/p/f" + std::to_string(i) + ".cc", 1 });

	auto const plan = agent_diagnostics::plan(Files(spec), 200, 50);

	OAK_ASSERT_EQ(plan.entries.size(), 50);
	OAK_ASSERT_EQ(plan.omitted_files, 350);
	OAK_ASSERT_EQ(plan.omitted_diagnostics, 350);
}

void test_another_project_cannot_spend_this_one_s_budget ()
{
	// The compound failure: an unrelated project holds far more than the cap
	// and sorts ahead of ours, so unscoped it spends the whole budget before
	// our file is reached. Scoped to the project that asked, ours is answered
	// in full.
	//
	// The names carry the test: `plan` walks the *scoped* vector, which is
	// ordered by uri, so an unrelated project that sorted after ours would let
	// this pass no matter what scoping did. That is the mistake this test made
	// on its first attempt, and indexing the unsorted input hid it twice over.
	std::vector<std::pair<std::string, size_t>> spec;
	spec.push_back({ "/tmp/zeta-target/main.cc", 4 });
	for(size_t i = 0; i < 300; ++i)
		spec.push_back({ "/tmp/alpha-noisy/f" + std::to_string(i) + ".cc", 5 });

	auto const files = Files(spec);

	auto const unscopedFiles = agent_diagnostics::in_scope(files, "");
	OAK_ASSERT_EQ(unscopedFiles.front().path.compare(0, 16, "/tmp/alpha-noisy"), 0); // the noisy project really is first

	auto const unscoped = agent_diagnostics::plan(unscopedFiles, 200, 50);
	bool listsTarget = false;
	for(auto const& entry : unscoped.entries)
		listsTarget = listsTarget || unscopedFiles[entry.index].path == "/tmp/zeta-target/main.cc";
	OAK_ASSERT(!listsTarget);            // starved, as the bug would have it
	OAK_ASSERT(unscoped.omitted_files);  // and reported as omitted, not dropped

	auto const scoped = agent_diagnostics::in_scope(files, "/tmp/zeta-target");
	auto const plan   = agent_diagnostics::plan(scoped, 200, 50);
	OAK_ASSERT_EQ(plan.entries.size(), 1);
	OAK_ASSERT_EQ(scoped[plan.entries[0].index].path, "/tmp/zeta-target/main.cc");
	OAK_ASSERT_EQ(plan.entries[0].take, 4);
	OAK_ASSERT_EQ(plan.omitted_files, 0);
}

void test_empty_files_cannot_crowd_out_real_diagnostics ()
{
	// A language server that clears a file's diagnostics publishes an empty
	// list, and the cache keeps the URI with an empty array. Sixty of those
	// sorting ahead of the real ones used to fill the file budget, answering
	// with sixty empty arrays while all 200 diagnostic slots went unspent.
	std::vector<std::pair<std::string, size_t>> spec;
	for(size_t i = 0; i < 60; ++i)
		spec.push_back({ "/p/aaa-cleared-" + std::to_string(i) + ".cc", 0 });
	spec.push_back({ "/p/zzz-broken.cc", 7 });

	auto const scoped = agent_diagnostics::in_scope(Files(spec), "");

	// Without the filter the answer is 50 empty envelopes and nothing else.
	auto const unfiltered = agent_diagnostics::plan(scoped, 200, 50);
	OAK_ASSERT_EQ(unfiltered.entries.size(), 50);
	OAK_ASSERT_EQ(unfiltered.omitted_diagnostics, 7); // the one file that mattered

	auto const listed = agent_diagnostics::with_diagnostics(scoped);
	auto const plan   = agent_diagnostics::plan(listed, 200, 50);
	OAK_ASSERT_EQ(plan.entries.size(), 1);
	OAK_ASSERT_EQ(listed[plan.entries[0].index].path, "/p/zzz-broken.cc");
	OAK_ASSERT_EQ(plan.entries[0].take, 7);

	// Dropping them is not truncation: nothing was lost with them.
	OAK_ASSERT_EQ(plan.omitted_files, 0);
	OAK_ASSERT_EQ(plan.omitted_diagnostics, 0);
}

void test_everything_fits ()
{
	auto const plan = agent_diagnostics::plan(Files({ { "/p/a.cc", 2 }, { "/p/b.cc", 3 } }), 200, 50);
	OAK_ASSERT_EQ(plan.entries.size(), 2);
	OAK_ASSERT_EQ(plan.omitted_files, 0);
	OAK_ASSERT_EQ(plan.omitted_diagnostics, 0);
	for(auto const& entry : plan.entries)
		OAK_ASSERT_EQ(entry.omitted, 0);

	OAK_ASSERT(agent_diagnostics::plan({}, 200, 50).entries.empty());
}
