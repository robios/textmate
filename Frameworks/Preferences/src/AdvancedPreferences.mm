#import "AdvancedPreferences.h"
#import "Keys.h"
#import <OakAppKit/OakPasteboard.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <MenuBuilder/MenuBuilder.h>
#import <settings/settings.h>

@implementation AdvancedPreferences
- (id)init
{
	if(self = [super initWithNibName:nil label:@"Advanced" image:PreferencesToolbarImage(@"gearshape.2", @"Advanced", nil)])
	{
		self.defaultsProperties = @{
			@"disableTypingPairs":                  kUserDefaultsDisableTypingPairsKey,
			@"disableAntiAlias":                    kUserDefaultsDisableAntiAliasKey,
			@"fontSmoothing":                       kUserDefaultsFontSmoothingKey,
			@"hideStatusBar":                       kUserDefaultsHideStatusBarKey,
			@"disableMinimapColors":                kUserDefaultsDisableMinimapColorsKey,
			@"showFavoritesInsteadOfUntitled":      kUserDefaultsShowFavoritesInsteadOfUntitledKey,
			@"lineNumberFontName":                  kUserDefaultsLineNumberFontNameKey,
			@"lineNumberScaleFactor":               kUserDefaultsLineNumberScaleFactorKey,
			@"tabItemMinWidth":                     kUserDefaultsTabItemMinWidthKey,
			@"tabItemMaxWidth":                     kUserDefaultsTabItemMaxWidthKey,
			@"disablePersistentClipboardHistory":   kUserDefaultsDisablePersistentClipboardHistory,
			@"clipboardHistoryKeepAtLeast":          kUserDefaultsClipboardHistoryKeepAtLeast,
			@"clipboardHistoryKeepAtMost":           kUserDefaultsClipboardHistoryKeepAtMost,
			@"clipboardHistoryDaysToKeep":           kUserDefaultsClipboardHistoryDaysToKeep,
			@"keepSearchResultsOnDoubleClick":       kUserDefaultsKeepSearchResultsOnDoubleClick,
			@"alwaysFindInDocument":                 kUserDefaultsAlwaysFindInDocument,
			@"fileBrowserOpenAnimationDisabled":     kUserDefaultsFileBrowserOpenAnimationDisabled,
			@"disableFolderStateRestore":            kUserDefaultsDisableFolderStateRestore,
			@"disableBundleSuggestions":             kUserDefaultsDisableBundleSuggestionsKey,
		};
	}
	return self;
}

// The change-mark setting is a three-case string, so it is bridged to an
// index the pop-up can bind to rather than stored as a tag.
- (NSInteger)diffMarksVisibilityIndex
{
	NSString* const mode = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsDiffMarksVisibilityKey];
	if([mode isEqualToString:kDiffMarksVisibilityAlways])
		return 0;
	if([mode isEqualToString:kDiffMarksVisibilityNever])
		return 2;
	return 1; // anything unrecognised reads as the default
}

- (void)setDiffMarksVisibilityIndex:(NSInteger)anIndex
{
	NSString* mode = kDiffMarksVisibilityWithPane;
	if(anIndex == 0)
		mode = kDiffMarksVisibilityAlways;
	else if(anIndex == 2)
		mode = kDiffMarksVisibilityNever;
	[NSUserDefaults.standardUserDefaults setObject:mode forKey:kUserDefaultsDiffMarksVisibilityKey];
}

// Unlike everything else on this pane this one lives in the settings
// system, not user defaults, so a project can override it in
// .tm_properties; the field here writes the global value.
- (NSString*)reviewBaseCommitLimit
{
	return [NSString stringWithFormat:@"%d", settings_for_path().get(kSettingsReviewBaseCommitLimitKey, kReviewBaseCommitLimitDefault)];
}

- (void)setReviewBaseCommitLimit:(NSString*)value
{
	// An empty field means "use the default" — which is what the
	// placeholder already shows — not zero. Zero is a real choice (the
	// commit list disappears) the reader makes by typing it, and clearing
	// the field should not silently land on it while the placeholder
	// promises 20.
	NSString* const trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	int32_t const limit = trimmed.length ? std::clamp<int>(trimmed.intValue, 0, kReviewBaseCommitLimitMax) : kReviewBaseCommitLimitDefault;
	settings_t::set(kSettingsReviewBaseCommitLimitKey, limit);
}

- (NSString*)grammarsToNeverSuggest
{
	NSArray* arr = [NSUserDefaults.standardUserDefaults stringArrayForKey:kUserDefaultsGrammarsToNeverSuggestKey];
	return [arr componentsJoinedByString:@", "];
}

- (void)setGrammarsToNeverSuggest:(NSString*)value
{
	NSArray* components = [value componentsSeparatedByString:@","];
	NSMutableArray* trimmed = [NSMutableArray array];
	for(NSString* s in components)
	{
		NSString* t = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if(t.length)
			[trimmed addObject:t];
	}
	[NSUserDefaults.standardUserDefaults setObject:trimmed forKey:kUserDefaultsGrammarsToNeverSuggestKey];
}

- (void)loadView
{
	NSButton* disableTypingPairsCheckBox              = OakCreateCheckBox(@"Disable typing pairs");
	NSButton* disableAntiAliasCheckBox                = OakCreateCheckBox(@"Disable text anti-aliasing");
	NSPopUpButton* fontSmoothingPopUp                 = OakCreatePopUpButton();
	NSButton* hideStatusBarCheckBox                   = OakCreateCheckBox(@"Hide status bar");
	NSButton* disableMinimapColorsCheckBox            = OakCreateCheckBox(@"Disable minimap colors");
	NSButton* showFavoritesCheckBox                   = OakCreateCheckBox(@"Show favorites instead of untitled");

	NSTextField* lineNumberFontField                  = [NSTextField textFieldWithString:@""];
	NSTextField* lineNumberScaleField                 = [NSTextField textFieldWithString:@""];
	NSTextField* tabMinWidthField                     = [NSTextField textFieldWithString:@""];
	NSTextField* tabMaxWidthField                     = [NSTextField textFieldWithString:@""];

	NSButton* disablePersistentClipboardCheckBox      = OakCreateCheckBox(@"Disable persistent clipboard history");
	NSTextField* clipboardKeepAtLeastField             = [NSTextField textFieldWithString:@""];
	NSTextField* clipboardKeepAtMostField              = [NSTextField textFieldWithString:@""];
	NSTextField* clipboardDaysToKeepField              = [NSTextField textFieldWithString:@""];

	NSButton* keepSearchResultsCheckBox               = OakCreateCheckBox(@"Keep search results on double-click");
	NSButton* alwaysFindInDocumentCheckBox             = OakCreateCheckBox(@"Always find in document");

	NSButton* disableOpenAnimationCheckBox             = OakCreateCheckBox(@"Disable open animation");
	NSButton* disableFolderStateRestoreCheckBox        = OakCreateCheckBox(@"Disable folder state restore");

	NSButton* disableBundleSuggestionsCheckBox         = OakCreateCheckBox(@"Disable bundle suggestions");
	NSTextField* grammarsToNeverSuggestField           = [NSTextField textFieldWithString:@""];

	NSPopUpButton* diffMarksPopUp                      = OakCreatePopUpButton();
	NSTextField* reviewBaseCommitLimitField            = [NSTextField textFieldWithString:@""];

	MBMenu const diffMarksItems = {
		{ @"Always" },
		{ @"Only while the diff pane is open (default)" },
		{ @"Never" },
	};
	MBCreateMenu(diffMarksItems, diffMarksPopUp.menu);

	MBMenu const fontSmoothingItems = {
		{ @"Disabled",                                      .tag = 0 },
		{ @"Enabled",                                       .tag = 1 },
		{ @"Disabled for dark themes",                      .tag = 2 },
		{ @"Disabled for dark themes on HiDPI (default)",   .tag = 3 },
	};
	MBCreateMenu(fontSmoothingItems, fontSmoothingPopUp.menu);

	for(NSTextField* field in @[ lineNumberFontField, lineNumberScaleField, tabMinWidthField, tabMaxWidthField, clipboardKeepAtLeastField, clipboardKeepAtMostField, clipboardDaysToKeepField, grammarsToNeverSuggestField, reviewBaseCommitLimitField ])
		[field.widthAnchor constraintEqualToConstant:360].active = YES;

	NSFont* hintFont = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	NSColor* hintColor = NSColor.secondaryLabelColor;

	NSTextField* (^makeHint)(NSString*) = ^NSTextField* (NSString* text) {
		NSTextField* label = OakCreateLabel(text, hintFont);
		label.textColor = hintColor;
		label.lineBreakMode = NSLineBreakByWordWrapping;
		label.maximumNumberOfLines = 2;
		return label;
	};

	NSGridView* gridView = [NSGridView gridViewWithViews:@[
		// Editor — rows 0-11
		@[ OakCreateLabel(@"Editor:"),       disableTypingPairsCheckBox ],                                                  // 0
		@[ NSGridCell.emptyContentView,      makeHint(@"Stops auto-closing of brackets, quotes, and other paired characters") ], // 1
		@[ NSGridCell.emptyContentView,      disableAntiAliasCheckBox ],                                                   // 2
		@[ NSGridCell.emptyContentView,      makeHint(@"Disables text anti-aliasing for a sharper, aliased look") ],       // 3
		@[ NSGridCell.emptyContentView,      fontSmoothingPopUp ],                                                         // 4
		@[ NSGridCell.emptyContentView,      makeHint(@"Controls subpixel font smoothing behavior by theme and display type") ], // 5
		@[ NSGridCell.emptyContentView,      hideStatusBarCheckBox ],                                                      // 6
		@[ NSGridCell.emptyContentView,      makeHint(@"Hides the status bar at the bottom of the editor window") ],       // 7
		@[ NSGridCell.emptyContentView,      disableMinimapColorsCheckBox ],                                               // 8
		@[ NSGridCell.emptyContentView,      makeHint(@"Renders the minimap in uniform gray instead of theme colors") ],   // 9
		@[ NSGridCell.emptyContentView,      showFavoritesCheckBox ],                                                      // 10
		@[ NSGridCell.emptyContentView,      makeHint(@"Shows the favorites dialog instead of an empty document at startup") ], // 11

		@[ ], // 12 — separator

		// Appearance — rows 13-20
		@[ OakCreateLabel(@"Line number font:"), lineNumberFontField ],                                                    // 13
		@[ NSGridCell.emptyContentView,      makeHint(@"PostScript font name for the gutter (e.g. Menlo-Regular)") ],      // 14
		@[ OakCreateLabel(@"Line number scale:"), lineNumberScaleField ],                                                  // 15
		@[ NSGridCell.emptyContentView,      makeHint(@"Scale factor relative to editor font size (default 0.8)") ],       // 16
		@[ OakCreateLabel(@"Min tab width:"), tabMinWidthField ],                                                          // 17
		@[ NSGridCell.emptyContentView,      makeHint(@"Minimum pixel width for document tabs (default 120)") ],           // 18
		@[ OakCreateLabel(@"Max tab width:"), tabMaxWidthField ],                                                          // 19
		@[ NSGridCell.emptyContentView,      makeHint(@"Maximum pixel width for document tabs (default 250)") ],           // 20

		@[ ], // 21 — separator

		// Clipboard — rows 22-29
		@[ OakCreateLabel(@"Clipboard:"),    disablePersistentClipboardCheckBox ],                                         // 22
		@[ NSGridCell.emptyContentView,      makeHint(@"Uses in-memory database only; clipboard history is lost on quit") ], // 23
		@[ OakCreateLabel(@"Keep at least:"), clipboardKeepAtLeastField ],                                                 // 24
		@[ NSGridCell.emptyContentView,      makeHint(@"Minimum number of clipboard entries to retain (default 25)") ],    // 25
		@[ OakCreateLabel(@"Keep at most:"), clipboardKeepAtMostField ],                                                   // 26
		@[ NSGridCell.emptyContentView,      makeHint(@"Maximum clipboard entries before pruning (default 500)") ],        // 27
		@[ OakCreateLabel(@"Days to keep:"), clipboardDaysToKeepField ],                                                   // 28
		@[ NSGridCell.emptyContentView,      makeHint(@"Entries older than this are pruned (default 30)") ],               // 29

		@[ ], // 30 — separator

		// Find — rows 31-34
		@[ OakCreateLabel(@"Find:"),         keepSearchResultsCheckBox ],                                                  // 31
		@[ NSGridCell.emptyContentView,      makeHint(@"Keeps the Find in Folder results window open after double-clicking a match") ], // 32
		@[ NSGridCell.emptyContentView,      alwaysFindInDocumentCheckBox ],                                               // 33
		@[ NSGridCell.emptyContentView,      makeHint(@"Find always searches the full document, even when text is selected") ], // 34

		@[ ], // 35 — separator

		// File Browser — rows 36-39
		@[ OakCreateLabel(@"File Browser:"), disableOpenAnimationCheckBox ],                                               // 36
		@[ NSGridCell.emptyContentView,      makeHint(@"Disables the expand/collapse animation in the file browser") ],    // 37
		@[ NSGridCell.emptyContentView,      disableFolderStateRestoreCheckBox ],                                          // 38
		@[ NSGridCell.emptyContentView,      makeHint(@"Stops restoring expanded/collapsed folder state when reopening projects") ], // 39

		@[ ], // 40 — separator

		// Bundles — rows 41-44
		@[ OakCreateLabel(@"Bundles:"),      disableBundleSuggestionsCheckBox ],                                           // 41
		@[ NSGridCell.emptyContentView,      makeHint(@"Stops suggesting bundle installation for unrecognized file types") ], // 42
		@[ OakCreateLabel(@"Never suggest for:"), grammarsToNeverSuggestField ],                                           // 43
		@[ NSGridCell.emptyContentView,      makeHint(@"Comma-separated list of grammar UUIDs to exclude from suggestions") ], // 44

		@[ ], // 45 — separator

		// Diff — rows 46-49
		@[ OakCreateLabel(@"Change marks:"), diffMarksPopUp ],                                                            // 46
		@[ NSGridCell.emptyContentView,      makeHint(@"Color bars while the diff pane is open, otherwise the gutter's own icons; untracked files show none") ], // 47
		@[ OakCreateLabel(@"Base commits:"), reviewBaseCommitLimitField ],                                                // 48
		@[ NSGridCell.emptyContentView,      makeHint(@"How many recent commits the review-base menu lists (default 20; 0 lists none). Projects can override reviewBaseCommitLimit in .tm_properties") ], // 49
	]];

	self.view = OakSetupScrollableGridView(gridView, { 12, 21, 30, 35, 40, 45 });

	// Editor bindings
	[disableTypingPairsCheckBox bind:NSValueBinding toObject:self withKeyPath:@"disableTypingPairs" options:nil];
	[disableAntiAliasCheckBox   bind:NSValueBinding toObject:self withKeyPath:@"disableAntiAlias"   options:nil];
	[fontSmoothingPopUp         bind:NSSelectedTagBinding toObject:self withKeyPath:@"fontSmoothing" options:nil];
	[hideStatusBarCheckBox      bind:NSValueBinding toObject:self withKeyPath:@"hideStatusBar"      options:nil];
	[disableMinimapColorsCheckBox bind:NSValueBinding toObject:self withKeyPath:@"disableMinimapColors" options:nil];
	[showFavoritesCheckBox      bind:NSValueBinding toObject:self withKeyPath:@"showFavoritesInsteadOfUntitled" options:nil];

	// Appearance bindings
	[lineNumberFontField  bind:NSValueBinding toObject:self withKeyPath:@"lineNumberFontName"      options:@{ NSNullPlaceholderBindingOption: @"Uses editor font when blank" }];
	[lineNumberScaleField bind:NSValueBinding toObject:self withKeyPath:@"lineNumberScaleFactor"    options:@{ NSNullPlaceholderBindingOption: @"0.8" }];
	[tabMinWidthField     bind:NSValueBinding toObject:self withKeyPath:@"tabItemMinWidth"          options:@{ NSNullPlaceholderBindingOption: @"120" }];
	[tabMaxWidthField     bind:NSValueBinding toObject:self withKeyPath:@"tabItemMaxWidth"          options:@{ NSNullPlaceholderBindingOption: @"250" }];

	// Clipboard bindings
	[disablePersistentClipboardCheckBox bind:NSValueBinding toObject:self withKeyPath:@"disablePersistentClipboardHistory" options:nil];
	[clipboardKeepAtLeastField bind:NSValueBinding toObject:self withKeyPath:@"clipboardHistoryKeepAtLeast" options:@{ NSNullPlaceholderBindingOption: @"25" }];
	[clipboardKeepAtMostField  bind:NSValueBinding toObject:self withKeyPath:@"clipboardHistoryKeepAtMost"  options:@{ NSNullPlaceholderBindingOption: @"500" }];
	[clipboardDaysToKeepField  bind:NSValueBinding toObject:self withKeyPath:@"clipboardHistoryDaysToKeep"  options:@{ NSNullPlaceholderBindingOption: @"30" }];

	// Find bindings
	[keepSearchResultsCheckBox    bind:NSValueBinding toObject:self withKeyPath:@"keepSearchResultsOnDoubleClick" options:nil];
	[alwaysFindInDocumentCheckBox bind:NSValueBinding toObject:self withKeyPath:@"alwaysFindInDocument"           options:nil];

	// File Browser bindings
	[disableOpenAnimationCheckBox       bind:NSValueBinding toObject:self withKeyPath:@"fileBrowserOpenAnimationDisabled" options:nil];
	[disableFolderStateRestoreCheckBox  bind:NSValueBinding toObject:self withKeyPath:@"disableFolderStateRestore"        options:nil];

	// Bundles bindings
	[disableBundleSuggestionsCheckBox bind:NSValueBinding toObject:self withKeyPath:@"disableBundleSuggestions"    options:nil];
	[grammarsToNeverSuggestField      bind:NSValueBinding toObject:self withKeyPath:@"grammarsToNeverSuggest"     options:@{ NSNullPlaceholderBindingOption: @"Comma-separated grammar UUIDs" }];

	// Diff bindings
	[diffMarksPopUp             bind:NSSelectedIndexBinding toObject:self withKeyPath:@"diffMarksVisibilityIndex" options:nil];
	[reviewBaseCommitLimitField bind:NSValueBinding         toObject:self withKeyPath:@"reviewBaseCommitLimit"    options:@{ NSNullPlaceholderBindingOption: @"20" }];
}
@end
