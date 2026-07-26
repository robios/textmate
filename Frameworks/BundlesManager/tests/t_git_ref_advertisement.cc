#include <BundlesManager/git_ref_advertisement.h>

// Fixtures are built rather than pasted so the framing stays honest: a hand
// written length prefix that disagrees with its payload would test the fixture,
// not the parser.
static std::string pkt (std::string const& payload)
{
	char length[5];
	snprintf(length, sizeof(length), "%04zx", payload.size() + 4);
	return std::string(length) + payload;
}

static std::string const kSHAMain    = "9c1cd0f16e4b1e1a89b0a34b0c99e0d4a1cbb0f1";
static std::string const kSHATag     = "0000000000000000000000000000000000000abc";
static std::string const kSHAPeeled  = "111111111111111111111111111111111111aaaa";
static std::string const kSHARelease = "2222222222222222222222222222222222220000";

static std::string advertisement ()
{
	std::string res = pkt("# service=git-upload-pack\n") + "0000";
	res += pkt(kSHAMain + " HEAD" + std::string(1, '\0') + "multi_ack thin-pack symref=HEAD:refs/heads/main object-format=sha1 agent=git/2.45\n");
	res += pkt(kSHAMain + " refs/heads/main\n");
	res += pkt(kSHARelease + " refs/heads/release\n");
	res += pkt(kSHATag + " refs/tags/v1.0\n");
	res += pkt(kSHAPeeled + " refs/tags/v1.0^{}\n");
	res += "0000";
	return res;
}

void test_branches_and_head_symref ()
{
	git::ref_advertisement_t ad = git::parse_ref_advertisement(advertisement());

	OAK_ASSERT_EQ((bool)ad, true);
	OAK_ASSERT_EQ(ad.head_symref, "refs/heads/main");
	OAK_ASSERT_EQ(ad.default_branch(), "main");

	OAK_ASSERT_EQ(ad.resolve("main"), kSHAMain);
	OAK_ASSERT_EQ(ad.resolve("release"), kSHARelease);
	OAK_ASSERT_EQ(ad.resolve("refs/heads/release"), kSHARelease);
	OAK_ASSERT_EQ(ad.resolve("HEAD"), kSHAMain);
}

void test_annotated_tag_resolves_to_the_peeled_commit ()
{
	git::ref_advertisement_t ad = git::parse_ref_advertisement(advertisement());

	// ‘v1.0’ names a tag object; what a checkout of it yields is the commit
	// advertised as ‘v1.0^{}’, and that is what we must record as installedSHA.
	OAK_ASSERT_EQ(ad.resolve("v1.0"), kSHAPeeled);
	OAK_ASSERT_EQ(ad.resolve("refs/tags/v1.0"), kSHAPeeled);
}

void test_missing_ref_resolves_to_nothing ()
{
	git::ref_advertisement_t ad = git::parse_ref_advertisement(advertisement());

	OAK_ASSERT_EQ(ad.resolve("master"), "");
	OAK_ASSERT_EQ(ad.resolve(""), "");

	// Eight hexadecimal characters is a SHA to a human and an unknown ref to us.
	// Expanding an abbreviation is not something the advertisement can do, so the
	// subscription goes unavailable rather than guessing.
	OAK_ASSERT_EQ(ad.resolve("deadbeef"), "");
}

void test_exact_revision_needs_no_advertisement ()
{
	git::ref_advertisement_t ad = git::parse_ref_advertisement(advertisement());

	OAK_ASSERT_EQ(ad.resolve(kSHATag), kSHATag);
	OAK_ASSERT_EQ(ad.resolve("9C1CD0F16E4B1E1A89B0A34B0C99E0D4A1CBB0F1"), kSHAMain);
}

void test_repository_without_a_head_symref ()
{
	// An empty repository advertises only the capabilities record. §7.2: we ask
	// for an explicit ref rather than guessing ‘main’.
	std::string data = pkt("# service=git-upload-pack\n") + "0000";
	data += pkt(std::string(40, '0') + " capabilities^{}" + std::string(1, '\0') + "multi_ack agent=git/2.45\n") + "0000";

	git::ref_advertisement_t ad = git::parse_ref_advertisement(data);
	OAK_ASSERT_EQ((bool)ad, true);
	OAK_ASSERT_EQ(ad.default_branch(), "");
	OAK_ASSERT_EQ(ad.resolve("main"), "");
}

void test_malformed_input_is_rejected_rather_than_half_read ()
{
	std::string good = advertisement();

	OAK_ASSERT_EQ((bool)git::parse_ref_advertisement(""), false);
	OAK_ASSERT_EQ((bool)git::parse_ref_advertisement("<html>404</html>"), false);          // Not pkt-line framed at all
	OAK_ASSERT_EQ((bool)git::parse_ref_advertisement(good.substr(0, good.size() - 20)), false); // Truncated mid packet
	OAK_ASSERT_EQ((bool)git::parse_ref_advertisement(good.substr(0, 6)), false);           // Length prefix without its payload
	OAK_ASSERT_EQ((bool)git::parse_ref_advertisement("0002"), false);                      // Protocol v2 delimiter, which we never ask for
	OAK_ASSERT_EQ((bool)git::parse_ref_advertisement(pkt("not-a-sha refs/heads/main\n")), false);
	OAK_ASSERT_EQ((bool)git::parse_ref_advertisement(pkt("ERR repository not found\n")), false);
}

void test_service_announcement_is_not_a_ref ()
{
	git::ref_advertisement_t ad = git::parse_ref_advertisement(advertisement());
	OAK_ASSERT_EQ(ad.refs.size(), 5);
	OAK_ASSERT_EQ(ad.refs.find("# service=git-upload-pack") == ad.refs.end(), true);
}
