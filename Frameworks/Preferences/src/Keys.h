// =======
// = API =
// =======

void RegisterDefaults ();

// =========
// = Files =
// =========

extern NSString* const kUserDefaultsDisableSessionRestoreKey;
extern NSString* const kUserDefaultsDisableNewDocumentAtStartupKey;
extern NSString* const kUserDefaultsDisableNewDocumentAtReactivationKey;
extern NSString* const kUserDefaultsShowFavoritesInsteadOfUntitledKey;

// ============
// = Projects =
// ============

extern NSString* const kUserDefaultsFoldersOnTopKey;
extern NSString* const kUserDefaultsShowFileExtensionsKey;
extern NSString* const kUserDefaultsInitialFileBrowserURLKey;
extern NSString* const kUserDefaultsFileBrowserPlacementKey;
extern NSString* const kUserDefaultsFileBrowserSingleClickToOpenKey;
extern NSString* const kUserDefaultsFileBrowserOpenAnimationDisabled;
extern NSString* const kUserDefaultsFileBrowserStyleKey;
extern NSString* const kUserDefaultsHTMLOutputPlacementKey;
extern NSString* const kUserDefaultsTerminalPlacementKey;
extern NSString* const kUserDefaultsMarkdownPreviewPlacementKey;
extern NSString* const kUserDefaultsDisableFileBrowserWindowResizeKey;
extern NSString* const kUserDefaultsAutoRevealFileKey;
extern NSString* const kUserDefaultsAllowExpandingLinksKey;
extern NSString* const kUserDefaultsAllowExpandingPackagesKey;
extern NSString* const kUserDefaultsDisableTabReorderingKey;
extern NSString* const kUserDefaultsDisableTabAutoCloseKey;
extern NSString* const kUserDefaultsDisableTabBarCollapsingKey;

// ===========
// = Bundles =
// ===========

// =============
// = Variables =
// =============

extern NSString* const kUserDefaultsEnvironmentVariablesKey;

// ============
// = Terminal =
// ============

extern NSString* const kUserDefaultsMateInstallPathKey;
extern NSString* const kUserDefaultsMateInstallVersionKey;

extern NSString* const kUserDefaultsDisableRMateServerKey;
extern NSString* const kUserDefaultsRMateServerListenKey;
extern NSString* const kUserDefaultsRMateServerPortKey;

extern NSString* const kRMateServerListenLocalhost;
extern NSString* const kRMateServerListenRemote;

// ================
// = Registration =
// ================

extern NSString* const kUserDefaultsLicenseOwnerKey;

// ==============
// = Appearance =
// ==============

extern NSString* const kUserDefaultsDisableAntiAliasKey;
extern NSString* const kUserDefaultsLineNumbersKey;
extern NSString* const kUserDefaultsLineNumberScaleFactorKey;
extern NSString* const kUserDefaultsLineNumberFontNameKey;

// ==========
// = Review =
// ==========

// How loudly the gutter shows buffer-vs-review-base changes. One of the
// three values below; anything else (or nothing) reads as the default,
// “with pane”.
extern NSString* const kUserDefaultsDiffMarksVisibilityKey;

extern NSString* const kDiffMarksVisibilityAlways;  // colour bars at all times
extern NSString* const kDiffMarksVisibilityWithPane; // bars with the pane open, the gutter's own icons otherwise
extern NSString* const kDiffMarksVisibilityNever;   // no in-gutter indication at all

// How many commits the review-base selector offers. A setting rather
// than a preference: how far back a reader wants to review is a
// property of the repository they are in, so `.tm_properties` can carry
// a different depth per project, with the preferences pane writing the
// global default. Shared here because both the pane and the service
// clamp it, and a clamp that disagreed would be a silent bug.
extern char const* const kSettingsReviewBaseCommitLimitKey;
extern int32_t const kReviewBaseCommitLimitDefault;
extern int32_t const kReviewBaseCommitLimitMax;

// ==============
// = Formatters =
// ==============

extern NSString* const kUserDefaultsFormatterConfigurationsKey;

// =========
// = Other =
// =========

extern NSString* const kUserDefaultsFolderSearchFollowLinksKey;

// ============
// = Advanced =
// ============

// Editor
extern NSString* const kUserDefaultsDisableTypingPairsKey;
extern NSString* const kUserDefaultsFontSmoothingKey;
extern NSString* const kUserDefaultsHideStatusBarKey;
extern NSString* const kUserDefaultsDisableMinimapColorsKey;

// Tabs
extern NSString* const kUserDefaultsTabItemMinWidthKey;
extern NSString* const kUserDefaultsTabItemMaxWidthKey;

// Find
extern NSString* const kUserDefaultsKeepSearchResultsOnDoubleClick;
extern NSString* const kUserDefaultsAlwaysFindInDocument;

// File Browser
extern NSString* const kUserDefaultsDisableFolderStateRestore;

// Bundles
extern NSString* const kUserDefaultsDisableBundleSuggestionsKey;
extern NSString* const kUserDefaultsGrammarsToNeverSuggestKey;
