#import "BundlesPreferences.h"
#import "BundleListItem.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <BundlesManager/BundlesManager.h>
#import <BundlesManager/BundleSubscriptionManager.h>
#import <BundlesManager/github_url.h>
#import <OakFoundation/OakFoundation.h>
#import <ns/ns.h>
#import <OakAppKit/NSAlert Additions.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakAppKit/OakScopeBarView.h>

static NSUserInterfaceItemIdentifier const kTableColumnIdentifierInstalled   = @"Installed";
static NSUserInterfaceItemIdentifier const kTableColumnIdentifierBundleName  = @"BundleName";
static NSUserInterfaceItemIdentifier const kTableColumnIdentifierWebLink     = @"WebLink";
static NSUserInterfaceItemIdentifier const kTableColumnIdentifierSource      = @"Source";
static NSUserInterfaceItemIdentifier const kTableColumnIdentifierUpdated     = @"Updated";
static NSUserInterfaceItemIdentifier const kTableColumnIdentifierDescription = @"Description";

static NSUserInterfaceItemIdentifier const kTableColumnIdentifierSourceName       = @"SourceName";
static NSUserInterfaceItemIdentifier const kTableColumnIdentifierSourceRepository = @"SourceRepository";
static NSUserInterfaceItemIdentifier const kTableColumnIdentifierSourceBranch     = @"SourceBranch";
static NSUserInterfaceItemIdentifier const kTableColumnIdentifierSourceBundles    = @"SourceBundles";


@interface BundleInstallHelper : NSObject
@property (nonatomic) NSMutableSet* itemsBeingInstalled;
@property (nonatomic) NSString* bundleInstallActivityText;
@property (nonatomic, getter = isBusy, readonly) BOOL busy;
@property (nonatomic, readonly) NSString* activityText;
@end

@implementation BundleInstallHelper
+ (instancetype)sharedInstance
{
	static BundleInstallHelper* sharedInstance = [self new];
	return sharedInstance;
}

+ (NSSet*)keyPathsForValuesAffectingBusy
{
	return [NSSet setWithObjects:@"itemsBeingInstalled", nil];
}

+ (NSSet*)keyPathsForValuesAffectingActivityText
{
	return [NSSet setWithObjects:@"bundleInstallActivityText", nil];
}

- (instancetype)init
{
	if(self = [super init])
	{
		_itemsBeingInstalled = [NSMutableSet set];
	}
	return self;
}

- (BOOL)isBusy
{
	return _itemsBeingInstalled.count != 0;
}

- (NSString*)activityText
{
	if(_bundleInstallActivityText)
		return _bundleInstallActivityText;

	if(NSDate* date = [NSUserDefaults.standardUserDefaults objectForKey:kUserDefaultsLastBundleUpdateCheckKey])
	{
		NSString* dateString = [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
#if defined(MAC_OS_X_VERSION_10_15) && (MAC_OS_X_VERSION_10_15 <= MAC_OS_X_VERSION_MAX_ALLOWED)
		if(@available(macos 10.15, *))
			dateString = -[date timeIntervalSinceNow] < 5 ? @"Just now" : [[[NSRelativeDateTimeFormatter alloc] init] localizedStringForDate:date relativeToDate:NSDate.now];
#endif
		return [NSString stringWithFormat:@"Bundle index last updated: %@", dateString];
	}

	return @"";
}

- (void)beginActivityForItem:(BundleListItem*)item message:(NSString*)message
{
	[self willChangeValueForKey:@"itemsBeingInstalled"];
	[_itemsBeingInstalled addObject:item];
	[self didChangeValueForKey:@"itemsBeingInstalled"];

	self.bundleInstallActivityText = message;
}

- (void)endActivityForItem:(BundleListItem*)item message:(NSString*)message
{
	self.bundleInstallActivityText = message;

	[self willChangeValueForKey:@"itemsBeingInstalled"];
	[_itemsBeingInstalled removeObject:item];
	[self didChangeValueForKey:@"itemsBeingInstalled"];
}

- (void)installItem:(BundleListItem*)item
{
	if([_itemsBeingInstalled containsObject:item])
		return;

	switch(item.kind)
	{
		case BundleListItemKindSigned:    [self installSignedBundleForItem:item];  break;
		case BundleListItemKindCandidate: [self installCandidateForItem:item];     break;
		default:                                                                  break;
	}
}

- (void)uninstallItem:(BundleListItem*)item
{
	if([_itemsBeingInstalled containsObject:item])
		return;

	if(item.kind == BundleListItemKindSubscription)
			[self uninstallSubscriptionForItem:item];
	else if(item.kind == BundleListItemKindSigned)
	{
		[BundlesManager.sharedInstance uninstallBundle:item.bundle];
		self.bundleInstallActivityText = [NSString stringWithFormat:@"Uninstalled ‘%@’ bundle.", item.name];
	}
}

// The signed path has no per-bundle update of its own — its only updater is the
// automatic one that runs when the index changes — so an explicit update means
// installing again, which fetches whatever the index publishes now.
- (void)updateItem:(BundleListItem*)item
{
	if([_itemsBeingInstalled containsObject:item])
		return;

	if(item.kind == BundleListItemKindSubscription)
	{
		BundleSubscription* subscription = item.subscription;
		[self beginActivityForItem:item message:[NSString stringWithFormat:@"Updating ‘%@’ bundle…", subscription.name]];
		[BundleSubscriptionManager.sharedInstance updateSubscription:subscription completionHandler:^(NSError* error){
			[self endActivityForItem:item message:error ? error.localizedDescription : [NSString stringWithFormat:@"Updated ‘%@’ bundle.", subscription.name]];
		}];
	}
	else if(item.kind == BundleListItemKindSigned)
	{
		[self installSignedBundleForItem:item];
	}
}

- (void)installSignedBundleForItem:(BundleListItem*)item
{
	Bundle* bundle = item.bundle;
	[self beginActivityForItem:item message:[NSString stringWithFormat:@"Installing ‘%@’ bundle…", bundle.name]];

	[BundlesManager.sharedInstance installBundles:@[ bundle ] completionHandler:^(NSArray<Bundle*>* bundles){
		NSString* message;
		if(!bundle.installed)
			message = [NSString stringWithFormat:@"Error installing ‘%@’ bundle.", bundle.name];
		else if(bundles.count == 1)
			message = [NSString stringWithFormat:@"Installed ‘%@’ bundle.", bundle.name];
		else if(bundles.count == 2)
			message = [NSString stringWithFormat:@"Installed ‘%@’ bundle and one dependency.", bundle.name];
		else
			message = [NSString stringWithFormat:@"Installed ‘%@’ bundle and %ld dependencies.", bundle.name, bundles.count-1];

		[self endActivityForItem:item message:message];
	}];
}

- (void)installCandidateForItem:(BundleListItem*)item
{
	BundleCandidate* candidate = item.candidate;

	// Replacing an official bundle is framed as giving something up, not as a
	// preference, and it is never reached without this being said out loud.
	if(item.requiresReplacingSignedBundle)
	{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText     = [NSString stringWithFormat:@"Replace the official “%@” bundle?", candidate.name];
		alert.informativeText = @"The official bundle is verified with TextMate’s signing key. A subscription is not: it is code fetched from a GitHub repository, and TextMate can only check that its UUID still matches.\n\nThe official copy is kept until the replacement is in place, and unsubscribing offers to restore it.";
		[alert addButtonWithTitle:@"Replace"];
		[alert addButtonWithTitle:@"Cancel"];
		if([alert runModal] != NSAlertFirstButtonReturn)
			return;

		[self beginActivityForItem:item message:[NSString stringWithFormat:@"Replacing ‘%@’ bundle…", candidate.name]];
		[BundleSubscriptionManager.sharedInstance replaceSignedBundleWithCandidate:candidate completionHandler:^(BundleSubscription* subscription, NSError* error){
			[self endActivityForItem:item message:error ? error.localizedDescription : [NSString stringWithFormat:@"Replaced ‘%@’ bundle.", candidate.name]];
		}];
		return;
	}

	[self beginActivityForItem:item message:[NSString stringWithFormat:@"Installing ‘%@’ bundle…", candidate.name]];
	[BundleSubscriptionManager.sharedInstance installCandidate:candidate completionHandler:^(BundleSubscription* subscription, NSError* error){
		[self endActivityForItem:item message:error ? error.localizedDescription : [NSString stringWithFormat:@"Installed ‘%@’ bundle.", candidate.name]];
	}];
}

- (void)uninstallSubscriptionForItem:(BundleListItem*)item
{
	BundleSubscription* subscription = item.subscription;

	if(subscription.replacesSigned)
	{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText     = [NSString stringWithFormat:@"Restore the official “%@” bundle?", subscription.name];
		alert.informativeText = @"This subscription replaced an official bundle. TextMate can download and verify the official copy again before removing the subscription.";
		[alert addButtonWithTitle:@"Restore Official"];
		[alert addButtonWithTitle:@"Just Remove"];
		[alert addButtonWithTitle:@"Cancel"];

		NSModalResponse response = [alert runModal];
		if(response == NSAlertThirdButtonReturn)
			return;

		if(response == NSAlertFirstButtonReturn)
		{
			[self beginActivityForItem:item message:[NSString stringWithFormat:@"Restoring official ‘%@’ bundle…", subscription.name]];
			[BundleSubscriptionManager.sharedInstance restoreSignedBundleForSubscription:subscription completionHandler:^(NSError* error){
				[self endActivityForItem:item message:error ? error.localizedDescription : [NSString stringWithFormat:@"Restored official ‘%@’ bundle.", subscription.name]];
			}];
			return;
		}
	}

	[self beginActivityForItem:item message:[NSString stringWithFormat:@"Removing ‘%@’ bundle…", subscription.name]];
	[BundleSubscriptionManager.sharedInstance uninstallSubscription:subscription completionHandler:^(NSError* error){
		[self endActivityForItem:item message:error ? error.localizedDescription : [NSString stringWithFormat:@"Removed ‘%@’ bundle.", subscription.name]];
	}];
}
@end

@interface BundleListItem (BundlesInstallPreferences)
@property (nonatomic) NSControlStateValue installedCellState;
@end

@implementation BundleListItem (BundlesInstallPreferences)
+ (NSSet*)keyPathsForValuesAffectingInstalledCellState
{
	return [NSSet setWithObjects:@"installed", @"bundleInstallHelper.itemsBeingInstalled", nil];
}

- (BundleInstallHelper*)bundleInstallHelper
{
	return BundleInstallHelper.sharedInstance;
}

- (NSControlStateValue)installedCellState
{
	return [self.bundleInstallHelper.itemsBeingInstalled containsObject:self] ? NSControlStateValueMixed : (self.isInstalled ? NSControlStateValueOn : NSControlStateValueOff);
}

- (void)setInstalledCellState:(NSControlStateValue)newValue
{
	if(self.installedCellState == NSControlStateValueOff && newValue != NSControlStateValueOff)
		[self.bundleInstallHelper installItem:self];
	else if(self.installedCellState == NSControlStateValueOn && newValue != NSControlStateValueOn)
		[self.bundleInstallHelper uninstallItem:self];
}
@end

// One row of the sources list: a tap, or a repository subscribed to on its own.
// Both are *sources* rather than bundles, which is why they need a list of their
// own rather than a place in the one above. A row with neither is the one being
// typed into.
@interface BundleSourceItem : NSObject
@property (nonatomic) BundleTap*          tap;
@property (nonatomic) BundleSubscription* subscription;
@property (nonatomic, readonly) NSString* name;
@property (nonatomic) NSString* repository;          // owner/repository, which is all github.com needs
@property (nonatomic) NSString* branch;
@property (nonatomic, readonly) NSString* bundleCount;
@property (nonatomic, readonly, getter = isPlaceholder) BOOL placeholder;
@end

@implementation BundleSourceItem
+ (NSArray<BundleSourceItem*>*)currentItems
{
	BundleSubscriptionManager* manager = BundleSubscriptionManager.sharedInstance;

	NSMutableArray* res = [NSMutableArray array];
	for(BundleTap* tap in manager.taps)
	{
		BundleSourceItem* item = [[BundleSourceItem alloc] init];
		item.tap = tap;
		[res addObject:item];
	}

	for(BundleSubscription* subscription in manager.subscriptions)
	{
		// A bundle that came from a tap has that tap as its source; only a
		// repository subscribed to on its own is a source in its own right.
		if(subscription.tapIdentifier)
			continue;

		BundleSourceItem* item = [[BundleSourceItem alloc] init];
		item.subscription = subscription;
		[res addObject:item];
	}

	return res;
}

- (BOOL)isPlaceholder { return !_tap && !_subscription; }

- (NSString*)name
{
	if(_tap)
		return _tap.name ?: self.repository;
	return _subscription.name ?: @"";
}

- (NSString*)repository
{
	NSString* url = _tap ? _tap.url : _subscription.url;
	if(url)
		return [url stringByReplacingOccurrencesOfString:@"https://github.com/" withString:@""];
	return _repository ?: @"";
}

- (NSString*)branch
{
	if(_tap)
		return _tap.trackingRef ?: @"";
	if(_subscription)
		return _subscription.effectiveRef ?: @"";
	return _branch ?: @"";
}

- (NSString*)bundleCount
{
	if(_tap)
	{
		NSUInteger count = [BundleSubscriptionManager.sharedInstance catalogueForTap:_tap].candidates.count;
		return count ? [NSString stringWithFormat:@"%lu", count] : @"—";
	}
	return _subscription ? @"1" : @"";
}
@end

@interface BundlesPreferences () <NSTableViewDelegate, NSMenuDelegate, NSTableViewDataSource>
{
	NSMutableSet*              _enabledCategories;
	NSArrayController*         _arrayController;
	OakScopeBarViewController* _scopeBar;
	NSSearchField*             _searchField;
	NSTableView*               _bundlesTableView;

	BundleListItem*            _contextMenuItem;

	NSTableView*               _sourcesTableView;
	NSButton*                  _removeSourceButton;
	NSArray<BundleSourceItem*>* _sourceItems;
	BundleSourceItem*          _rowBeingAdded;
}
@property (nonatomic) NSUInteger selectedIndex;
@property (nonatomic) NSArray<BundleListItem*>* items;
@end

@implementation BundlesPreferences
- (NSImage*)toolbarItemImage { return PreferencesToolbarImage(@"puzzlepiece.extension", @"Bundles", [NSWorkspace.sharedWorkspace iconForContentType:[UTType typeWithFilenameExtension:@"tmbundle"]]); }

- (id)init
{
	if(self = [self initWithNibName:nil bundle:nil])
	{
		self.identifier = @"Bundles";
		self.title      = @"Bundles";

		_enabledCategories = [NSMutableSet set];
		_selectedIndex     = NSNotFound;
		_items             = [BundleListItem currentItems];
		_sourceItems       = [BundleSourceItem currentItems];

		_scopeBar = [[OakScopeBarViewController alloc] init];
		_scopeBar.allowsEmptySelection = YES;
		_scopeBar.controlSize = NSControlSizeSmall;

		// Both lists feed one table, so both have to be able to refresh it
		[BundlesManager.sharedInstance addObserver:self forKeyPath:@"bundles" options:0 context:nullptr];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(subscriptionsDidChange:) name:BundleSubscriptionsDidChangeNotification object:nil];
	}
	return self;
}

- (void)dealloc
{
	[BundlesManager.sharedInstance removeObserver:self forKeyPath:@"bundles"];
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	[self reloadItems];
}

- (void)subscriptionsDidChange:(NSNotification*)notification
{
	[self reloadItems];
}

- (void)reloadItems
{
	self.items = [BundleListItem currentItems];
	[self reloadSources];
	[self updateCategories];
}

- (void)updateCategories
{
	NSMutableSet* categories = [NSMutableSet set];
	for(BundleListItem* item in _items)
	{
		if(NSString* category = item.category)
			[categories addObject:category];
	}

	NSArray* labels = [[categories allObjects] sortedArrayUsingSelector:@selector(localizedCompare:)];
	if(![labels isEqualToArray:_scopeBar.labels])
	{
		_scopeBar.labels = labels;
		self.selectedIndex = NSNotFound;
	}
}

- (NSTableColumn*)columnWithIdentifier:(NSUserInterfaceItemIdentifier)identifier title:(NSString*)title editable:(BOOL)editable width:(CGFloat)width resizingMask:(NSTableColumnResizingOptions)resizingMask
{
	NSTableColumn* tableColumn = [[NSTableColumn alloc] initWithIdentifier:identifier];

	tableColumn.title        = title;
	tableColumn.editable     = editable;
	tableColumn.width        = width;
	tableColumn.resizingMask = resizingMask;

	if(resizingMask == NSTableColumnNoResizing)
	{
		tableColumn.minWidth = width;
		tableColumn.maxWidth = width;
	}

	return tableColumn;
}

- (void)loadView
{
	[self updateCategories];

	_searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
	_searchField.controlSize = NSControlSizeSmall;
	_searchField.font        = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	_searchField.action      = @selector(filterStringDidChange:);
	[_searchField.cell setScrollable:YES];
	[_searchField.cell setSendsSearchStringImmediately:YES];

	_arrayController = [[NSArrayController alloc] init];
	_arrayController.avoidsEmptySelection = NO;
	_arrayController.sortDescriptors = @[
		[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCompare:)],
		[NSSortDescriptor sortDescriptorWithKey:@"installed" ascending:YES],
		[NSSortDescriptor sortDescriptorWithKey:@"downloadLastUpdated" ascending:YES],
		[NSSortDescriptor sortDescriptorWithKey:@"textSummary" ascending:YES selector:@selector(localizedCompare:)]
	];

	NSTableColumn* installedTableColumn   = [self columnWithIdentifier:kTableColumnIdentifierInstalled   title:@""            editable:YES width:16  resizingMask:NSTableColumnNoResizing];
	NSTableColumn* bundleTableColumn      = [self columnWithIdentifier:kTableColumnIdentifierBundleName  title:@"Bundle"      editable:NO  width:130 resizingMask:NSTableColumnUserResizingMask];
	NSTableColumn* linkTableColumn        = [self columnWithIdentifier:kTableColumnIdentifierWebLink     title:@""            editable:NO  width:16  resizingMask:NSTableColumnNoResizing];
	NSTableColumn* sourceTableColumn      = [self columnWithIdentifier:kTableColumnIdentifierSource      title:@"Source"      editable:NO  width:150 resizingMask:NSTableColumnUserResizingMask];
	NSTableColumn* updatedTableColumn     = [self columnWithIdentifier:kTableColumnIdentifierUpdated     title:@"Updated"     editable:NO  width:90  resizingMask:NSTableColumnNoResizing];
	NSTableColumn* descriptionTableColumn = [self columnWithIdentifier:kTableColumnIdentifierDescription title:@"Description" editable:NO  width:140 resizingMask:NSTableColumnAutoresizingMask];

	NSButtonCell* installedCell = [[NSButtonCell alloc] init];
	installedCell.buttonType       = NSButtonTypeSwitch;
	installedCell.allowsMixedState = YES;
	installedCell.controlSize      = NSControlSizeSmall;
	installedCell.title            = @"";
	installedTableColumn.dataCell = installedCell;

	NSButtonCell* linkCell = [[NSButtonCell alloc] init];
	linkCell.buttonType  = NSButtonTypeMomentaryChange;
	linkCell.bezelStyle  = NSBezelStyleInline;
	linkCell.bordered    = NO;
	linkCell.controlSize = NSControlSizeSmall;
	linkCell.title       = @"";
	linkCell.action      = @selector(didClickBundleLink:);
	linkCell.target      = self;
	linkTableColumn.dataCell = linkCell;

	// The cell shows text rather than a date so that a row we have no date for
	// can say so; the column still sorts on the date itself.
	NSTextFieldCell* updatedCell = [[NSTextFieldCell alloc] initTextCell:@""];
	updatedCell.alignment = NSTextAlignmentRight;
	updatedTableColumn.dataCell = updatedCell;

	_bundlesTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
	_bundlesTableView.allowsColumnReordering  = NO;
	_bundlesTableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	_bundlesTableView.delegate                = self;

	for(NSTableColumn* tableColumn in @[ installedTableColumn, bundleTableColumn, linkTableColumn, sourceTableColumn, updatedTableColumn, descriptionTableColumn ])
		[_bundlesTableView addTableColumn:tableColumn];
	[_bundlesTableView setIndicatorImage:[NSImage imageNamed:@"NSAscendingSortIndicator"] inTableColumn:bundleTableColumn];

	// Per-bundle actions live here rather than in a row of buttons that would be
	// disabled for most selections: what you can do to a bundle depends on what
	// kind of bundle it is, and a menu can say so per item.
	NSMenu* bundleMenu = [[NSMenu alloc] init];
	bundleMenu.delegate = self;
	// Otherwise AppKit re-enables every item whose target answers its action,
	// right after menuNeedsUpdate: has decided which of them make sense here.
	bundleMenu.autoenablesItems = NO;
	[[bundleMenu addItemWithTitle:@"Update" action:@selector(didClickUpdate:) keyEquivalent:@""] setTarget:self];
	[[bundleMenu addItemWithTitle:@"Compare Changes…" action:@selector(didClickCompare:) keyEquivalent:@""] setTarget:self];
	[[bundleMenu addItemWithTitle:@"Update Automatically" action:@selector(didToggleAutoUpdate:) keyEquivalent:@""] setTarget:self];
	[bundleMenu addItem:[NSMenuItem separatorItem]];
	[[bundleMenu addItemWithTitle:@"Open Repository Page" action:@selector(didClickOpenHomePage:) keyEquivalent:@""] setTarget:self];
	_bundlesTableView.menu = bundleMenu;

	NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	scrollView.hasVerticalScroller   = YES;
	scrollView.hasHorizontalScroller = NO;
	scrollView.autohidesScrollers    = YES;
	scrollView.borderType            = NSBezelBorder;
	scrollView.documentView          = _bundlesTableView;

	// ========
	// = Taps =
	// ========

	// A source is not a bundle, so it gets its own list instead of a row in the
	// one above — and the list is where it is typed in, too: a sheet for two
	// short strings is more ceremony than the thing it collects.
	NSTableColumn* sourceNameColumn       = [self columnWithIdentifier:kTableColumnIdentifierSourceName       title:@"Source"     editable:NO  width:150 resizingMask:NSTableColumnUserResizingMask];
	NSTableColumn* sourceRepositoryColumn = [self columnWithIdentifier:kTableColumnIdentifierSourceRepository title:@"Repository" editable:YES width:230 resizingMask:NSTableColumnAutoresizingMask];
	NSTableColumn* sourceBranchColumn     = [self columnWithIdentifier:kTableColumnIdentifierSourceBranch     title:@"Branch"     editable:YES width:110 resizingMask:NSTableColumnUserResizingMask];
	NSTableColumn* sourceBundlesColumn    = [self columnWithIdentifier:kTableColumnIdentifierSourceBundles    title:@"Bundles"    editable:NO  width:60  resizingMask:NSTableColumnNoResizing];

	NSTextFieldCell* sourceBundlesCell = [[NSTextFieldCell alloc] initTextCell:@""];
	sourceBundlesCell.alignment = NSTextAlignmentRight;
	sourceBundlesColumn.dataCell = sourceBundlesCell;

	NSTextFieldCell* repositoryCell = [[NSTextFieldCell alloc] initTextCell:@""];
	repositoryCell.editable = YES;
	repositoryCell.placeholderString = @"owner/repository";
	sourceRepositoryColumn.dataCell = repositoryCell;

	NSTextFieldCell* branchCell = [[NSTextFieldCell alloc] initTextCell:@""];
	branchCell.editable = YES;
	branchCell.placeholderString = @"default";
	sourceBranchColumn.dataCell = branchCell;

	_sourcesTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
	_sourcesTableView.allowsColumnReordering  = NO;
	_sourcesTableView.allowsMultipleSelection = NO;
	_sourcesTableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	_sourcesTableView.delegate                = self;
	_sourcesTableView.dataSource              = self;

	for(NSTableColumn* tableColumn in @[ sourceNameColumn, sourceRepositoryColumn, sourceBranchColumn, sourceBundlesColumn ])
		[_sourcesTableView addTableColumn:tableColumn];

	NSScrollView* tapsScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	tapsScrollView.hasVerticalScroller   = YES;
	tapsScrollView.hasHorizontalScroller = NO;
	tapsScrollView.autohidesScrollers    = YES;
	tapsScrollView.borderType            = NSBezelBorder;
	tapsScrollView.documentView          = _sourcesTableView;

	// Sized and joined the way the Variables pane does it, which is the way the
	// rest of the system does it
	NSButton* addSourceButton = [NSButton buttonWithImage:[NSImage imageNamed:NSImageNameAddTemplate] target:self action:@selector(didClickAddSource:)];
	addSourceButton.toolTip   = @"Add a tap or a bundle repository: type owner/repository, optionally a branch, then press Return.";

	_removeSourceButton = [NSButton buttonWithImage:[NSImage imageNamed:NSImageNameRemoveTemplate] target:self action:@selector(didClickRemoveSource:)];
	_removeSourceButton.toolTip = @"Remove the selected source, or take back the row being added.";

	for(NSButton* button in @[ addSourceButton, _removeSourceButton ])
		button.bezelStyle = NSBezelStyleSmallSquare;

	NSButton* updateBundlesCheckbox = [NSButton checkboxWithTitle:@"Check for and install updates automatically" target:nil action:nil];

	NSButton* refreshButton = [NSButton buttonWithTitle:@"Refresh Now" target:self action:@selector(didClickRefresh:)];
	refreshButton.controlSize = NSControlSizeSmall;
	refreshButton.font        = [NSFont messageFontOfSize:NSFont.smallSystemFontSize];
	refreshButton.toolTip     = @"Check the bundle index, every tap, and every subscription now — whether or not scheduled checks are enabled.";

	NSTextField* statusTextField = [NSTextField labelWithString:@""];
	statusTextField.textColor = NSColor.secondaryLabelColor;
	statusTextField.font = [NSFont messageFontOfSize:NSFont.smallSystemFontSize];

	NSProgressIndicator* progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
	progressIndicator.controlSize          = NSControlSizeSmall;
	progressIndicator.displayedWhenStopped = NO;
	progressIndicator.style                = NSProgressIndicatorStyleSpinning;

	NSVisualEffectView* footerView = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
	footerView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
	footerView.material     = NSVisualEffectMaterialTitlebar;

	NSDictionary* footerViews = @{
		@"divider": OakCreateNSBoxSeparator(),
		@"spinner": progressIndicator,
		@"status":  statusTextField,
	};
	OakAddAutoLayoutViewsToSuperview(footerViews.allValues, footerView);
	[footerView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[divider]|"                        options:0 metrics:nil views:footerViews]];
	[footerView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[spinner]-(>=8)-[status]-(>=8)-|" options:NSLayoutFormatAlignAllCenterY metrics:nil views:footerViews]];
	[footerView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[divider(==1)]-4-[status]-4-|"     options:0 metrics:nil views:footerViews]];
	[statusTextField.centerXAnchor constraintEqualToAnchor:footerView.centerXAnchor].active = YES;

	NSDictionary* views = @{
		@"scopeBar":      _scopeBar.view,
		@"search":        _searchField,
		@"scrollView":    scrollView,
		@"tapsScroll":    tapsScrollView,
		@"add":           addSourceButton,
		@"remove":        _removeSourceButton,
		@"updateBundles": updateBundlesCheckbox,
		@"refresh":       refreshButton,
		@"footer":        footerView,
	};

	NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 622, 516)];
	OakAddAutoLayoutViewsToSuperview(views.allValues, view);

	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-8-[scopeBar]-(>=8)-[search(>=50,<=100,==100@250)]-8-|"                        options:NSLayoutFormatAlignAllCenterY metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[scrollView(>=50)]-|"                                                         options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[tapsScroll]-|"                                                               options:0 metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[add(==20)]-(-1)-[remove(==add)]-(>=20)-|"                                    options:NSLayoutFormatAlignAllTop|NSLayoutFormatAlignAllBottom metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[updateBundles]-(>=8)-[refresh]-|"                                            options:NSLayoutFormatAlignAllCenterY metrics:nil views:views]];
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[footer]|"                                                                     options:NSLayoutFormatAlignAllCenterY metrics:nil views:views]];

	// The bundle list keeps whatever the window does not need for the rest, so
	// growing the window grows the part worth growing.
	// The two things that govern every bundle — the automatic check and Refresh
	// Now — sit with the bundle list they act on, above the sources below.
	[view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-8-[search]-8-[scrollView(>=120)]-8-[updateBundles]-16-[tapsScroll(==92)]-8-[add(==19)]-16-[footer]|" options:0 metrics:nil views:views]];

	// ============
	// = Bindings =
	// ============

	[_arrayController bind:NSContentBinding toObject:self withKeyPath:@"items" options:nil];
	[_scopeBar bind:NSValueBinding toObject:self withKeyPath:@"selectedIndex" options:nil];

	[_bundlesTableView bind:NSContentBinding          toObject:_arrayController withKeyPath:@"arrangedObjects" options:nil];
	[_bundlesTableView bind:NSSelectionIndexesBinding toObject:_arrayController withKeyPath:@"selectionIndexes" options:nil];

	[installedTableColumn   bind:NSValueBinding toObject:_arrayController withKeyPath:@"arrangedObjects.installedCellState" options:nil];
	[bundleTableColumn      bind:NSValueBinding toObject:_arrayController withKeyPath:@"arrangedObjects.name" options:nil];
	[sourceTableColumn      bind:NSValueBinding toObject:_arrayController withKeyPath:@"arrangedObjects.source" options:nil];
	[updatedTableColumn     bind:NSValueBinding toObject:_arrayController withKeyPath:@"arrangedObjects.updatedText" options:nil];
	[descriptionTableColumn bind:NSValueBinding toObject:_arrayController withKeyPath:@"arrangedObjects.textSummary" options:nil];

	[updateBundlesCheckbox bind:NSValueBinding toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:@"values.disableBundleUpdates" options:@{ NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName }];

	[progressIndicator bind:NSAnimateBinding toObject:BundleInstallHelper.sharedInstance withKeyPath:@"busy" options:nil];
	[statusTextField   bind:NSValueBinding   toObject:BundleInstallHelper.sharedInstance withKeyPath:@"activityText" options:nil];

	self.view = view;

	[self updateSourceButtons];
}

- (void)viewWillAppear
{
	BundleInstallHelper.sharedInstance.bundleInstallActivityText = nil;
	[self reloadItems];
}

- (void)viewDidAppear
{
	NSResponder* firstResponder = self.view.window.firstResponder;
	if(!firstResponder || firstResponder == self.view.window || ([firstResponder isKindOfClass:[NSView class]] && [(NSView*)firstResponder isDescendantOf:self.view]))
		[self.view.window makeFirstResponder:_bundlesTableView];
}

- (void)setSelectedIndex:(NSUInteger)newSelectedIndex
{
	_selectedIndex = newSelectedIndex;
	[_enabledCategories removeAllObjects];
	if(_selectedIndex < _scopeBar.labels.count)
		[_enabledCategories addObject:_scopeBar.labels[_selectedIndex]];
	[self filterStringDidChange:self];
}

- (void)filterStringDidChange:(id)sender
{
	NSMutableArray* predicates = [NSMutableArray array];
	if(OakNotEmptyString(_searchField.stringValue))
		[predicates addObject:[NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", _searchField.stringValue]];
	if(_enabledCategories.count)
		[predicates addObject:[NSPredicate predicateWithFormat:@"category IN %@", _enabledCategories]];
	_arrayController.filterPredicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
	[_arrayController rearrangeObjects];
}

// ===============================
// = Per-bundle actions and info =
// ===============================

// Right-clicking acts on the row under the cursor whether or not it is
// selected, which is what every other table on the system does.
- (BundleListItem*)clickedItem
{
	NSInteger row = _bundlesTableView.clickedRow != -1 ? _bundlesTableView.clickedRow : _bundlesTableView.selectedRow;
	NSArray* items = _arrayController.arrangedObjects;
	return row >= 0 && row < items.count ? items[row] : nil;
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	// Captured now: clickedRow is only meaningful while the menu is coming up,
	// and the action runs after it has gone.
	_contextMenuItem = self.clickedItem;

	BundleListItem* item = _contextMenuItem;
	BundleSubscription* subscription = item.subscription;

	for(NSMenuItem* menuItem in menu.itemArray)
	{
		if(menuItem.action == @selector(didClickUpdate:))
		{
			menuItem.enabled = item.hasUpdate;
			menuItem.title   = item.hasUpdate ? @"Update" : @"No Update Available";
		}
		else if(menuItem.action == @selector(didClickCompare:))
		{
			// Reading the diff before accepting it is the affordance that makes
			// pinning worth its friction, so it belongs next to Update.
			menuItem.hidden  = !item.canUpdateAutomatically;
			menuItem.enabled = [BundleSubscriptionManager.sharedInstance compareURLForSubscription:subscription] != nil;
		}
		else if(menuItem.action == @selector(didToggleAutoUpdate:))
		{
			// Only a subscription has a per-bundle setting: the signed path has
			// one switch for all of it, at the bottom of this pane.
			menuItem.hidden  = !item.canUpdateAutomatically;
			menuItem.state   = subscription.autoUpdate ? NSControlStateValueOn : NSControlStateValueOff;
			menuItem.enabled = subscription != nil;
		}
		else if(menuItem.action == @selector(didClickOpenHomePage:))
		{
			menuItem.enabled = item.htmlURL != nil;
		}
	}
}

- (void)didToggleAutoUpdate:(id)sender
{
	if(BundleSubscription* subscription = _contextMenuItem.subscription)
	{
		[BundleSubscriptionManager.sharedInstance setAutoUpdate:!subscription.autoUpdate forSubscription:subscription completionHandler:^(NSError* error){
			if(error)
				BundleInstallHelper.sharedInstance.bundleInstallActivityText = error.localizedDescription;
		}];
	}
}

- (void)didClickCompare:(id)sender
{
	if(NSURL* url = [BundleSubscriptionManager.sharedInstance compareURLForSubscription:_contextMenuItem.subscription])
		[NSWorkspace.sharedWorkspace openURL:url];
}

- (void)didClickUpdate:(id)sender
{
	if(BundleListItem* item = _contextMenuItem)
		[BundleInstallHelper.sharedInstance updateItem:item];
}

- (void)didClickOpenHomePage:(id)sender
{
	if(NSURL* url = _contextMenuItem.htmlURL)
		[NSWorkspace.sharedWorkspace openURL:url];
}

// ===========
// = Sources =
// ===========

- (void)reloadSources
{
	NSMutableArray* items = [[BundleSourceItem currentItems] mutableCopy];

	// The row being typed into is not a source yet, so it is not in the registry
	// — it has to survive every reload the registry provokes until it is either
	// committed or abandoned.
	if(_rowBeingAdded)
		[items addObject:_rowBeingAdded];

	_sourceItems = items;
	[_sourcesTableView reloadData];
	[self updateSourceButtons];
}

- (void)updateSourceButtons
{
	// Enabled for the row being typed into as well: “−” is how that row is
	// taken back, and there is nothing else it could mean there.
	NSInteger row = _sourcesTableView.selectedRow;
	_removeSourceButton.enabled = row >= 0 && row < _sourceItems.count;
}

- (void)didClickRemoveSource:(id)sender
{
	[self removeSelectedSource];
}

- (void)didClickAddSource:(id)sender
{
	if(_rowBeingAdded)
		return;

	_rowBeingAdded = [[BundleSourceItem alloc] init];
	[self reloadSources];

	NSInteger row = _sourceItems.count - 1;
	[_sourcesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	[_sourcesTableView scrollRowToVisible:row];
	[_sourcesTableView editColumn:[_sourcesTableView columnWithIdentifier:kTableColumnIdentifierSourceRepository] row:row withEvent:nil select:YES];
}

- (void)discardRowBeingAdded
{
	if(!_rowBeingAdded)
		return;

	_rowBeingAdded = nil;
	[self reloadSources];
}

// The empty row is the whole registration dialog: type owner/repository — or an
// owner, to see what they publish — optionally a branch, and press Return.
- (void)commitRowBeingAdded
{
	if(!_rowBeingAdded)
		return;

	NSString* repository = [_rowBeingAdded.repository stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	NSString* branch     = [_rowBeingAdded.branch stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	[self discardRowBeingAdded];

	if(!repository.length)
		return;

	if(std::string owner = github::parse_owner_url(to_s(repository)); !owner.empty())
		return [self addBundlesFromOwner:to_ns(owner) ref:branch];

	BundleInstallHelper.sharedInstance.bundleInstallActivityText = [NSString stringWithFormat:@"Adding %@…", repository];
	[BundleSubscriptionManager.sharedInstance addSourceWithURL:repository ref:branch completionHandler:^(BundleTap* tap, NSArray<BundleSubscription*>* subscriptions, NSError* error){
		if(error)
		{
			BundleInstallHelper.sharedInstance.bundleInstallActivityText = error.localizedDescription;
			[[NSAlert alertWithError:error] runModal];
		}
		else if(tap)
		{
			BundleInstallHelper.sharedInstance.bundleInstallActivityText = [NSString stringWithFormat:@"Added the ‘%@’ tap. Its bundles are listed above.", tap.name ?: repository];
		}
		else
		{
			BundleInstallHelper.sharedInstance.bundleInstallActivityText = subscriptions.count == 1 ? [NSString stringWithFormat:@"Installed ‘%@’ bundle.", subscriptions.firstObject.name] : [NSString stringWithFormat:@"Installed %lu bundles.", subscriptions.count];
		}
	}];
}

- (void)removeSelectedSource
{
	NSInteger row = _sourcesTableView.selectedRow;
	if(row < 0 || row >= _sourceItems.count)
		return;

	BundleSourceItem* item = _sourceItems[row];
	if(item.isPlaceholder)
	{
		[_sourcesTableView abortEditing];
		return [self discardRowBeingAdded];
	}

	if(BundleTap* tap = item.tap)
	{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText     = [NSString stringWithFormat:@"Remove the “%@” tap?", item.name];
		alert.informativeText = @"Bundles installed from this tap are kept. Each keeps following the branch, tag, or revision it is on now, and can be changed or removed on its own afterwards.";
		[alert addButtonWithTitle:@"Remove"];
		[alert addButtonWithTitle:@"Cancel"];
		if([alert runModal] != NSAlertFirstButtonReturn)
			return;

		[BundleSubscriptionManager.sharedInstance removeTap:tap completionHandler:^(NSError* error){
			BundleInstallHelper.sharedInstance.bundleInstallActivityText = error ? error.localizedDescription : [NSString stringWithFormat:@"Removed the ‘%@’ tap.", item.name];
		}];
	}
	else if(BundleSubscription* subscription = item.subscription)
	{
		// Removing a one-off repository *is* uninstalling its bundle, restore
		// prompt and all — there is nothing else it could mean.
		BundleListItem* bundleItem = nil;
		for(BundleListItem* candidate in self.items)
		{
			if(candidate.subscription == subscription)
				bundleItem = candidate;
		}

		if(bundleItem)
			[BundleInstallHelper.sharedInstance uninstallItem:bundleItem];
	}
}

- (void)didClickRefresh:(id)sender
{
	// Explicit refresh runs both paths even when scheduled checks are off, and
	// still honours each subscription’s own autoUpdate setting.
	BundleInstallHelper.sharedInstance.bundleInstallActivityText = @"Checking for bundle updates…";
	[BundlesManager.sharedInstance refreshBundlesWithCompletionHandler:^{
		BundleInstallHelper.sharedInstance.bundleInstallActivityText = @"Finished checking for bundle updates.";
	}];
}

- (void)addBundlesFromOwner:(NSString*)owner ref:(NSString*)ref
{
	BundleInstallHelper.sharedInstance.bundleInstallActivityText = [NSString stringWithFormat:@"Listing repositories for %@…", owner];
	[BundleSubscriptionManager.sharedInstance enumerateRepositoriesForOwner:owner completionHandler:^(NSArray<NSString*>* repositoryURLs, NSString* message, NSError* error){
		BundleInstallHelper.sharedInstance.bundleInstallActivityText = error ? error.localizedDescription : message;
		if(error)
			return (void)[[NSAlert alertWithError:error] runModal];

		if(NSArray<NSString*>* chosen = [self runRepositorySelectionForOwner:owner repositoryURLs:repositoryURLs message:message])
			[self addBundlesFromRepositoryURLs:chosen atIndex:0 ref:ref installed:0];
	}];
}

// One at a time and through the ordinary path: each repository is resolved,
// validated, and refused on collision exactly as a hand-typed URL would be.
- (void)addBundlesFromRepositoryURLs:(NSArray<NSString*>*)repositoryURLs atIndex:(NSUInteger)index ref:(NSString*)ref installed:(NSUInteger)installed
{
	if(index == repositoryURLs.count)
	{
		BundleInstallHelper.sharedInstance.bundleInstallActivityText = [NSString stringWithFormat:@"Installed %lu of %lu repositories.", installed, repositoryURLs.count];
		return;
	}

	NSString* url = repositoryURLs[index];
	BundleInstallHelper.sharedInstance.bundleInstallActivityText = [NSString stringWithFormat:@"Adding %@…", url.lastPathComponent];
	[BundleSubscriptionManager.sharedInstance addSubscriptionForRepositoryURL:url ref:ref completionHandler:^(NSArray<BundleSubscription*>* subscriptions, NSError* error){
		if(error)
			os_log_error(OS_LOG_DEFAULT, "Failed to subscribe to %{public}@: %{public}@", url, error.localizedDescription);
		[self addBundlesFromRepositoryURLs:repositoryURLs atIndex:index + 1 ref:ref installed:installed + subscriptions.count];
	}];
}

- (NSArray<NSString*>*)runRepositorySelectionForOwner:(NSString*)owner repositoryURLs:(NSArray<NSString*>*)repositoryURLs message:(NSString*)message
{
	if(repositoryURLs.count == 0)
	{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText     = [NSString stringWithFormat:@"No repositories found for “%@”.", owner];
		alert.informativeText = message ?: @"Only public repositories can be subscribed to.";
		[alert addButtonWithTitle:@"OK"];
		[alert runModal];
		return nil;
	}

	NSMutableArray<NSButton*>* checkboxes = [NSMutableArray array];
	for(NSString* url in repositoryURLs)
	{
		NSButton* checkbox = [NSButton checkboxWithTitle:url.lastPathComponent target:nil action:nil];
		checkbox.toolTip = url;
		// Nothing is subscribed by accident: an owner’s repositories are mostly
		// not bundles, and the ones that are still cost a signature.
		checkbox.state = [url.lastPathComponent.lowercaseString hasSuffix:@".tmbundle"] ? NSControlStateValueOn : NSControlStateValueOff;
		[checkboxes addObject:checkbox];
	}

	NSStackView* checkboxStack = [NSStackView stackViewWithViews:checkboxes];
	checkboxStack.orientation = NSUserInterfaceLayoutOrientationVertical;
	checkboxStack.alignment   = NSLayoutAttributeLeading;
	checkboxStack.spacing     = 2;

	NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 360, 220)];
	scrollView.hasVerticalScroller = YES;
	scrollView.borderType          = NSBezelBorder;
	scrollView.documentView        = checkboxStack;

	[checkboxStack.leadingAnchor constraintEqualToAnchor:scrollView.contentView.leadingAnchor constant:4].active = YES;
	[checkboxStack.topAnchor constraintEqualToAnchor:scrollView.contentView.topAnchor constant:4].active = YES;

	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText     = [NSString stringWithFormat:@"Subscribe to repositories from “%@”", owner];
	alert.informativeText = message ?: @"Repositories whose name ends in .tmbundle are pre-selected. Anything that turns out not to be a bundle is skipped.";
	alert.accessoryView   = scrollView;
	[alert addButtonWithTitle:@"Subscribe"];
	[alert addButtonWithTitle:@"Cancel"];

	if([alert runModal] != NSAlertFirstButtonReturn)
		return nil;

	NSMutableArray<NSString*>* res = [NSMutableArray array];
	[checkboxes enumerateObjectsUsingBlock:^(NSButton* checkbox, NSUInteger i, BOOL*){
		if(checkbox.state == NSControlStateValueOn)
			[res addObject:repositoryURLs[i]];
	}];
	return res.count ? res : nil;
}

// =============================
// = Sources table data source =
// =============================

- (NSInteger)numberOfRowsInTableView:(NSTableView*)aTableView
{
	return aTableView == _sourcesTableView ? _sourceItems.count : 0;
}

- (id)tableView:(NSTableView*)aTableView objectValueForTableColumn:(NSTableColumn*)aTableColumn row:(NSInteger)rowIndex
{
	if(aTableView != _sourcesTableView || rowIndex >= _sourceItems.count)
		return nil;

	BundleSourceItem* item = _sourceItems[rowIndex];
	if([aTableColumn.identifier isEqualToString:kTableColumnIdentifierSourceName])
		return item.name;
	else if([aTableColumn.identifier isEqualToString:kTableColumnIdentifierSourceRepository])
		return item.repository;
	else if([aTableColumn.identifier isEqualToString:kTableColumnIdentifierSourceBranch])
		return item.branch;
	else if([aTableColumn.identifier isEqualToString:kTableColumnIdentifierSourceBundles])
		return item.bundleCount;
	return nil;
}

- (void)tableView:(NSTableView*)aTableView setObjectValue:(id)anObject forTableColumn:(NSTableColumn*)aTableColumn row:(NSInteger)rowIndex
{
	if(aTableView != _sourcesTableView || rowIndex >= _sourceItems.count)
		return;

	BundleSourceItem* item = _sourceItems[rowIndex];
	NSString* value = [anObject isKindOfClass:[NSString class]] ? anObject : @"";

	if([aTableColumn.identifier isEqualToString:kTableColumnIdentifierSourceRepository])
	{
		// Kept, not acted on: the row is only registered once the user says it
		// is finished, which leaves them free to fill in Branch first.
		if(item.isPlaceholder)
			item.repository = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		return;
	}

	if(![aTableColumn.identifier isEqualToString:kTableColumnIdentifierSourceBranch])
		return;

	NSString* branch = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	if(item.isPlaceholder)
	{
		item.branch = branch;
	}
	else if(BundleTap* tap = item.tap)
	{
		if([branch isEqualToString:item.branch])
			return;

		// The manager owns the change, so a catalogue that could not be fetched
		// or recorded leaves the tap on the branch it is still following.
		[BundleSubscriptionManager.sharedInstance setRef:branch forTap:tap completionHandler:^(NSError* error){
			if(error)
				BundleInstallHelper.sharedInstance.bundleInstallActivityText = error.localizedDescription;
			[self reloadSources];
		}];
	}
	else if(BundleSubscription* subscription = item.subscription)
	{
		if(![branch isEqualToString:item.branch])
		{
			[BundleSubscriptionManager.sharedInstance setRef:branch forSubscription:subscription completionHandler:^(NSError* error){
				if(error)
					BundleInstallHelper.sharedInstance.bundleInstallActivityText = error.localizedDescription;
				[self reloadSources];
			}];
		}
	}
}

// ========================
// = NSTableView Delegate =
// ========================

// Return is the commit gesture, and the only one: leaving the repository field
// by any other route — Tab to Branch, a click elsewhere — keeps the row exactly
// as typed, so a tap whose catalogue is on a branch can be entered in the order
// the columns are in. “−” takes the row back.
- (void)controlTextDidEndEditing:(NSNotification*)notification
{
	if(notification.object != _sourcesTableView || !_rowBeingAdded)
		return;

	if([notification.userInfo[@"NSTextMovement"] integerValue] != NSTextMovementReturn)
		return;

	// After the field editor has finished with the row it is about to remove
	dispatch_async(dispatch_get_main_queue(), ^{
		[self commitRowBeingAdded];
	});
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification
{
	if(notification.object == _sourcesTableView)
		[self updateSourceButtons];
}

// What the detail line used to say, without spending a line of the window on it
- (NSString*)tableView:(NSTableView*)aTableView toolTipForCell:(NSCell*)aCell rect:(NSRectPointer)rect tableColumn:(NSTableColumn*)aTableColumn row:(NSInteger)rowIndex mouseLocation:(NSPoint)mouseLocation
{
	if(aTableView != _bundlesTableView)
		return nil;

	NSArray* items = _arrayController.arrangedObjects;
	return rowIndex >= 0 && rowIndex < items.count ? [(BundleListItem*)items[rowIndex] detailText] : nil;
}

- (void)tableView:(NSTableView*)aTableView didClickTableColumn:(NSTableColumn*)aTableColumn
{
	NSDictionary* map = @{
		kTableColumnIdentifierInstalled:   @"installed",
		kTableColumnIdentifierBundleName:  @"name",
		kTableColumnIdentifierUpdated:     @"downloadLastUpdated",
		kTableColumnIdentifierDescription: @"textSummary"
	};

	NSString* key = map[aTableColumn.identifier];
	if(!key)
		return;

	NSMutableArray* descriptors = [_arrayController.sortDescriptors mutableCopy];

	NSInteger i = 0;
	while(i < descriptors.count && ![_arrayController.sortDescriptors[i].key isEqualToString:key])
		++i;

	if(i == descriptors.count)
		return;

	NSSortDescriptor* descriptor = descriptors[i];
	descriptor = i == 0 || !descriptor.ascending ? [descriptor reversedSortDescriptor] : descriptor;
	[descriptors removeObjectAtIndex:i];
	[descriptors insertObject:descriptor atIndex:0];

	_arrayController.sortDescriptors = descriptors;

	for(NSTableColumn* tableColumn in [_bundlesTableView tableColumns])
		[aTableView setIndicatorImage:nil inTableColumn:tableColumn];
	[aTableView setIndicatorImage:[NSImage imageNamed:(descriptor.ascending ? @"NSAscendingSortIndicator" : @"NSDescendingSortIndicator")] inTableColumn:aTableColumn];
}

- (void)tableView:(NSTableView*)aTableView willDisplayCell:(id)aCell forTableColumn:(NSTableColumn*)aTableColumn row:(NSInteger)rowIndex
{
	if(aTableView != _bundlesTableView)
		return;

	BundleListItem* item = _arrayController.arrangedObjects[rowIndex];
	if([aTableColumn.identifier isEqualToString:kTableColumnIdentifierWebLink])
	{
		BOOL enabled = item.htmlURL ? YES : NO;
		[aCell setEnabled:enabled];
		[aCell setImage:enabled ? [NSImage imageNamed:@"NSFollowLinkFreestandingTemplate"] : nil];
	}
	else if([aTableColumn.identifier isEqualToString:kTableColumnIdentifierInstalled])
	{
		[aCell setEnabled:item.canChangeInstalledState];
	}
	else if([aTableColumn.identifier isEqualToString:kTableColumnIdentifierUpdated])
	{
		// Both branches, since cells are reused down the column
		[aCell setTextColor:item.hasUpdatedDate ? NSColor.controlTextColor : NSColor.tertiaryLabelColor];
	}
}

- (BOOL)tableView:(NSTableView*)aTableView shouldEditTableColumn:(NSTableColumn*)aTableColumn row:(NSInteger)rowIndex
{
	if(aTableView == _sourcesTableView)
	{
		if(rowIndex >= _sourceItems.count)
			return NO;

		// A source's repository can be typed once. Changing it afterwards would
		// mean "these bundles now come from somewhere else", which is a removal
		// and an addition, not an edit.
		if([aTableColumn.identifier isEqualToString:kTableColumnIdentifierSourceRepository])
			return _sourceItems[rowIndex].isPlaceholder;

		return [aTableColumn.identifier isEqualToString:kTableColumnIdentifierSourceBranch];
	}

	if([aTableColumn.identifier isEqualToString:kTableColumnIdentifierInstalled])
	{
		BundleListItem* item = _arrayController.arrangedObjects[rowIndex];
		return item.canChangeInstalledState && item.installedCellState != NSControlStateValueMixed;
	}
	return NO;
}

- (BOOL)tableView:(NSTableView*)aTableView shouldSelectRow:(NSInteger)rowIndex
{
	if(aTableView != _bundlesTableView)
		return YES;

	NSInteger clickedColumn = aTableView.clickedColumn;
	return clickedColumn != [aTableView columnWithIdentifier:kTableColumnIdentifierInstalled] && clickedColumn != [aTableView columnWithIdentifier:kTableColumnIdentifierWebLink];
}

- (void)didClickBundleLink:(NSTableView*)aTableView
{
	NSInteger rowIndex = aTableView.clickedRow;
	BundleListItem* item = _arrayController.arrangedObjects[rowIndex];
	if(item.htmlURL)
		[NSWorkspace.sharedWorkspace openURL:item.htmlURL];
}
@end
