#include <lsp/LSPBundleSettings.h>
#include <settings/settings.h>
#include <plist/plist.h>
#include <io/path.h>
#include <test/bundle_index.h>
#include <test/jail.h>

// Hermeticity: settings_for_path() always consults the real ~/.tm_properties
// (paths() ends at the passwd-database home directory, which cannot be
// redirected via $HOME), so a developer who configured lspCommand the
// pre-feature way would contaminate any “key is absent” assertion. Therefore
// “settings machinery is silent” is expressed with an explicitly empty
// settings_t, and settings_for_path() is only used where the jail explicitly
// assigns the asserted key — collect() processes deeper directories last, so
// the jail value always overrides anything inherited from the real home.
//
// The bundle side needs no such care: setup replaces the process-wide bundle
// index, and gen_test runs setup functions serially before the (parallel)
// test functions.

void setup_bundle_settings_fixtures ()
{
	// Real .tmPreferences file from disk — proves the on-disk item format works end-to-end (source.go → gopls)
	plist::dictionary_t goItem = plist::load(path::join(path::parent(__FILE__), "fixtures/Go LSP.tmPreferences"));

	static std::string const PythonLSP =
		"{	name     = 'Language Server';"
		"	scope    = 'source.python';"
		"	settings = {"
		"		lspCommand = 'pylsp';"
		"	};"
		"}";

	// A bundle can ship a server command but leave it opt-in via lspEnabled = false
	static std::string const LegacyLSP =
		"{	name     = 'Language Server';"
		"	scope    = 'source.legacy';"
		"	settings = {"
		"		lspCommand = 'legacy-ls';"
		"		lspEnabled = :false;"
		"	};"
		"}";

	// Author mistake: lspInitOptions as a nested dictionary instead of a JSON string
	static std::string const DictOptionsLSP =
		"{	name     = 'Language Server';"
		"	scope    = 'source.dictopts';"
		"	settings = {"
		"		lspInitOptions = { usePlaceholders = :true; };"
		"	};"
		"}";

	test::bundle_index_t bundleIndex;
	bundleIndex.add(bundles::kItemTypeSettings, goItem);
	bundleIndex.add(bundles::kItemTypeSettings, PythonLSP);
	bundleIndex.add(bundles::kItemTypeSettings, LegacyLSP);
	bundleIndex.add(bundles::kItemTypeSettings, DictOptionsLSP);
	bundleIndex.commit();
}

void test_bundle_value_used_when_settings_absent ()
{
	settings_t const settings; // empty ⇒ hermetically “absent”

	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPCommandKey, settings, scope::scope_t("source.go")), "gopls");
	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPInitOptionsKey, settings, scope::scope_t("source.go")), "{ \"usePlaceholders\": true }");
}

void test_tm_properties_wins_over_bundle ()
{
	test::jail_t jail;
	jail.set_content(".tm_properties", "[ source.go ]\nlspCommand = '/opt/bin/gopls -remote=auto'\n");
	settings_t const settings = settings_for_path(jail.path("main.go"), "source.go", jail.path());

	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPCommandKey, settings, scope::scope_t("source.go")), "/opt/bin/gopls -remote=auto");
}

void test_explicit_empty_command_disables_bundle_fallback ()
{
	// lspCommand = '' has always meant “no language server”; an explicit
	// (even empty) user value must shadow the bundle default.
	test::jail_t jail;
	jail.set_content(".tm_properties", "[ source.go ]\nlspCommand = ''\n");
	settings_t const settings = settings_for_path(jail.path("main.go"), "source.go", jail.path());

	OAK_ASSERT(settings.has(kSettingsLSPCommandKey));
	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPCommandKey, settings, scope::scope_t("source.go")), "");
}

void test_bundle_can_disable_lsp ()
{
	settings_t const settings; // empty ⇒ hermetically “absent”
	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPCommandKey, settings, scope::scope_t("source.legacy")), "legacy-ls");
	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPEnabledKey, settings, scope::scope_t("source.legacy"), true), false);

	// …and .tm_properties can re-enable what the bundle disabled
	test::jail_t jail;
	jail.set_content(".tm_properties", "[ source.legacy ]\nlspEnabled = true\n");
	settings_t const enabled = settings_for_path(jail.path("prog.lgy"), "source.legacy", jail.path());
	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPEnabledKey, enabled, scope::scope_t("source.legacy"), true), true);
}

void test_scope_selector_specificity ()
{
	settings_t const settings; // empty ⇒ hermetically “absent”

	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPCommandKey, settings, scope::scope_t("source.python")), "pylsp");

	// A source.python item must not leak into other scopes
	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPCommandKey, settings, scope::scope_t("source.rust")), "");
	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPCommandKey, settings, scope::scope_t("source.rust"), std::string("fallback")), "fallback");
}

void test_builtin_default_when_neither_source_defines_key ()
{
	settings_t const settings; // empty ⇒ hermetically “absent”

	// Go fixture defines no lspEnabled/lspRootPath — built-in defaults apply
	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPEnabledKey, settings, scope::scope_t("source.go"), true), true);
	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPRootPathKey, settings, scope::scope_t("source.go")), "");
}

void test_unsupported_bundle_value_type_ignored ()
{
	// A dict-typed lspInitOptions (instead of a JSON string) is ignored with
	// a logged warning; the built-in default applies.
	settings_t const settings;
	OAK_ASSERT_EQ(lsp::setting_with_bundle_fallback(kSettingsLSPInitOptionsKey, settings, scope::scope_t("source.dictopts")), "");
}
