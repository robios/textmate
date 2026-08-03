#import "AppController.h"
#import <oak/oak.h>
#import <text/ctype.h>
#import <text/parse.h>
#import <bundles/bundles.h>
#import <command/launcher.h>
#import <command/parser.h>
#import <cf/cf.h>
#import <ns/ns.h>
#import <OakAppKit/NSMenuItem Additions.h>
#import <OakAppKit/OakToolTip.h>
#import <MenuBuilder/MenuBuilder.h>
#import <OakFoundation/NSString Additions.h>
#import <OakTextView/OakTextView.h>
#import <oak/debug.h>
#import <BundleMenu/BundleMenu.h>
#import <theme/theme.h>
#import <settings/settings.h>

static NSString* NameForLocaleIdentifier (NSString* languageCode)
{
	NSString* localLanguage = nil;
	if(CFLocaleRef locale = CFLocaleCreate(kCFAllocatorDefault, (__bridge CFStringRef)languageCode))
	{
		localLanguage = [(NSString*)CFBridgingRelease(CFLocaleCopyDisplayNameForPropertyValue(locale, kCFLocaleIdentifier, (__bridge CFStringRef)languageCode)) capitalizedString];
		CFRelease(locale);
	}

	NSString* systemLangauge = [(NSString*)CFBridgingRelease(CFLocaleCopyDisplayNameForPropertyValue(CFLocaleGetSystem(), kCFLocaleIdentifier, (__bridge CFStringRef)languageCode)) capitalizedString];
	return localLanguage ?: systemLangauge ?: languageCode;
}

@implementation AppController (BundlesMenu)
- (BOOL)menuHasKeyEquivalent:(NSMenu*)aMenu forEvent:(NSEvent*)theEvent target:(id*)aTarget action:(SEL*)anAction
{
	return NO;
}

- (void)bundlesMenuNeedsUpdate:(NSMenu*)aMenu
{
	for(NSInteger i = aMenu.numberOfItems; i--; )
	{
		if([[aMenu itemAtIndex:i] isSeparatorItem])
			break;
		[aMenu removeItemAtIndex:i];
	}

	std::multimap<std::string, bundles::item_ptr, text::less_t> ordered;
	for(auto const& item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeBundle))
		ordered.emplace(item->name(), item);

	for(auto const& pair : ordered)
	{
		if(pair.second->menu().empty())
			continue;

		NSMenuItem* menuItem = [aMenu addItemWithTitle:[NSString stringWithCxxString:pair.first] action:NULL keyEquivalent:@""];
		menuItem.submenu = [[NSMenu alloc] initWithTitle:[NSString stringWithCxxString:pair.second->uuid()]];
		menuItem.submenu.delegate = BundleMenuDelegate.sharedInstance;
	}

	if(ordered.empty())
		[aMenu addItemWithTitle:@"No Bundles Loaded" action:@selector(nop:) keyEquivalent:@""];
}

// ===========================
// = Terminal Launchers Menu =
// ===========================

// Bundle commands that run in the terminal instead of inside TextMate, gathered
// beside the two agent CLIs the Terminal menu already starts. They are reachable
// without this — the Bundles menu and ⌃⌘T list them like any other command —
// but “start something in a terminal” is a thing a user looks for under Terminal.
//
// Answered here rather than on the window controller so the menu is populated
// with no window open too, which is the context the application-level route
// exists for: picking a launcher there opens the window it needs.
- (void)updateTerminalLaunchersMenu:(NSMenu*)aMenu
{
	// The real scope, empty when nothing is open — so a launcher restricted to
	// the file types it applies to keeps that restriction, here as everywhere.
	scope::context_t scope = "";
	if(OakTextView* textView = [NSApp targetForAction:@selector(scopeContext)])
		scope = [textView scopeContext];

	std::vector<bundles::item_ptr> const items = command::terminal_launchers(scope);
	OakAddBundlesToMenu(items, true, aMenu, @selector(performBundleItemWithUUIDStringFrom:));

	if(items.empty())
		[aMenu addItemWithTitle:@"No Launchers" action:@selector(nop:) keyEquivalent:@""];
}

+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		@"universalThemeUUID": @(kMacClassicThemeUUID),
		@"darkModeThemeUUID":  @(kTwilightThemeUUID),
	}];

	// MIGRATION from 2.0.12 and earlier
	__weak __block id token = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:NSApp queue:nil usingBlock:^(NSNotification* notification){
		[NSNotificationCenter.defaultCenter removeObserver:token];

		std::string const savedThemeUUID = settings_for_path().get(kSettingsThemeKey);
		if(savedThemeUUID != NULL_STR)
		{
			os_log(OS_LOG_DEFAULT, "Remove old theme setting from Global.tmProperties: %{public}@", to_ns(savedThemeUUID));
			settings_t::set(kSettingsThemeKey, NULL_STR);

			if(bundles::item_ptr themeItem = bundles::lookup(savedThemeUUID))
			{
				bool darkTheme = themeItem->value_for_field(bundles::kFieldSemanticClass).find("theme.dark") == 0;
				NSString* mode        = darkTheme ? @"dark"              : @"light";
				NSString* defaultsKey = darkTheme ? @"darkModeThemeUUID" : @"universalThemeUUID";

				os_log(OS_LOG_DEFAULT, "Set preferred appearance to %{public}@", mode);
				[NSUserDefaults.standardUserDefaults setObject:to_ns(savedThemeUUID) forKey:defaultsKey];
				[NSUserDefaults.standardUserDefaults setObject:mode forKey:@"themeAppearance"];
			}
		}

		[NSUserDefaults.standardUserDefaults removeObjectForKey:@"changeThemeBasedOnAppearance"];
	}];
}

- (void)takeThemeAppearanceFrom:(id)sender
{
	[NSUserDefaults.standardUserDefaults setObject:[sender representedObject] forKey:@"themeAppearance"];
}

- (void)takeUniversalThemeUUIDFrom:(id)sender
{
	[NSUserDefaults.standardUserDefaults setObject:[sender representedObject] forKey:@"universalThemeUUID"];
}

- (void)takeDarkThemeUUIDFrom:(id)sender
{
	[NSUserDefaults.standardUserDefaults setObject:[sender representedObject] forKey:@"darkModeThemeUUID"];
}

// The Markdown preview follows the editor theme until any of these three keys
// is set; “Use Editor Theme” returns to that state by clearing all of them.
// Unset keys fall back to the editor’s counterpart, so forcing just the
// appearance (say, light preview against a dark editor) is a single click.

- (void)selectMarkdownPreviewEditorTheme:(id)sender
{
	for(NSString* key in @[ @"markdownPreviewThemeAppearance", @"markdownPreviewUniversalThemeUUID", @"markdownPreviewDarkModeThemeUUID" ])
		[NSUserDefaults.standardUserDefaults removeObjectForKey:key];
}

- (void)takeMarkdownPreviewThemeAppearanceFrom:(id)sender
{
	[NSUserDefaults.standardUserDefaults setObject:[sender representedObject] forKey:@"markdownPreviewThemeAppearance"];
}

- (void)takeMarkdownPreviewUniversalThemeUUIDFrom:(id)sender
{
	[NSUserDefaults.standardUserDefaults setObject:[sender representedObject] forKey:@"markdownPreviewUniversalThemeUUID"];
}

- (void)takeMarkdownPreviewDarkThemeUUIDFrom:(id)sender
{
	[NSUserDefaults.standardUserDefaults setObject:[sender representedObject] forKey:@"markdownPreviewDarkModeThemeUUID"];
}

- (BOOL)validateThemeMenuItem:(NSMenuItem*)item
{
	if(item.action == @selector(takeThemeAppearanceFrom:))
	{
		NSString* savedValue = [NSUserDefaults.standardUserDefaults stringForKey:@"themeAppearance"];
		item.state = !item.representedObject && !savedValue || [item.representedObject isEqualToString:savedValue] ? NSControlStateValueOn : NSControlStateValueOff;

		NSString* label;
		NSString* defaultsKey;
		if([item.representedObject isEqualToString:@"light"])
		{
			label = @"Light Theme";
			defaultsKey = @"universalThemeUUID";
		}
		else if([item.representedObject isEqualToString:@"dark"])
		{
			label = @"Dark Theme";
			defaultsKey = @"darkModeThemeUUID";
		}

		if(defaultsKey)
		{
			NSString* themeUUID = [NSUserDefaults.standardUserDefaults stringForKey:defaultsKey];
			if(bundles::item_ptr themeItem = bundles::lookup(to_s(themeUUID)))
				item.title = [NSString stringWithFormat:@"%@ (%@)", label, to_ns(themeItem->name())];
		}
	}
	else if(item.action == @selector(takeUniversalThemeUUIDFrom:))
		item.state = [item.representedObject isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:@"universalThemeUUID"]] ? NSControlStateValueOn : NSControlStateValueOff;
	else if(item.action == @selector(takeDarkThemeUUIDFrom:))
		item.state = [item.representedObject isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:@"darkModeThemeUUID"]] ? NSControlStateValueOn : NSControlStateValueOff;
	else if(item.action == @selector(selectMarkdownPreviewEditorTheme:))
	{
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
		BOOL custom = [defaults objectForKey:@"markdownPreviewThemeAppearance"] || [defaults objectForKey:@"markdownPreviewUniversalThemeUUID"] || [defaults objectForKey:@"markdownPreviewDarkModeThemeUUID"];
		item.state = custom ? NSControlStateValueOff : NSControlStateValueOn;
	}
	else if(item.action == @selector(takeMarkdownPreviewThemeAppearanceFrom:))
	{
		// Checkmarks and labels show the effective value, i.e. the editor’s
		// setting whenever the preview’s own key is unset.
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
		NSString* effective = [defaults stringForKey:@"markdownPreviewThemeAppearance"] ?: [defaults stringForKey:@"themeAppearance"] ?: @"auto";
		item.state = [item.representedObject isEqualToString:effective] ? NSControlStateValueOn : NSControlStateValueOff;

		NSString* label;
		NSString* previewKey, *editorKey;
		if([item.representedObject isEqualToString:@"light"])
		{
			label      = @"Light Theme";
			previewKey = @"markdownPreviewUniversalThemeUUID";
			editorKey  = @"universalThemeUUID";
		}
		else if([item.representedObject isEqualToString:@"dark"])
		{
			label      = @"Dark Theme";
			previewKey = @"markdownPreviewDarkModeThemeUUID";
			editorKey  = @"darkModeThemeUUID";
		}

		if(previewKey)
		{
			NSString* themeUUID = [defaults stringForKey:previewKey] ?: [defaults stringForKey:editorKey];
			if(bundles::item_ptr themeItem = bundles::lookup(to_s(themeUUID)))
				item.title = [NSString stringWithFormat:@"%@ (%@)", label, to_ns(themeItem->name())];
		}
	}
	else if(item.action == @selector(takeMarkdownPreviewUniversalThemeUUIDFrom:))
	{
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
		NSString* effective = [defaults stringForKey:@"markdownPreviewUniversalThemeUUID"] ?: [defaults stringForKey:@"universalThemeUUID"];
		item.state = [item.representedObject isEqualToString:effective] ? NSControlStateValueOn : NSControlStateValueOff;
	}
	else if(item.action == @selector(takeMarkdownPreviewDarkThemeUUIDFrom:))
	{
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
		NSString* effective = [defaults stringForKey:@"markdownPreviewDarkModeThemeUUID"] ?: [defaults stringForKey:@"darkModeThemeUUID"];
		item.state = [item.representedObject isEqualToString:effective] ? NSControlStateValueOn : NSControlStateValueOff;
	}
	return YES;
}

// Shared by the editor’s Theme menu and the Markdown Preview Theme menu: same
// appearance section and light/dark theme submenus, differing only in the
// actions (and thereby the defaults keys) they drive. The preview variant adds
// a “Use Editor Theme” item and skips the themes’ key equivalents, which
// belong to the editor menu alone.
- (void)buildThemesMenu:(NSMenu*)aMenu forMarkdownPreview:(BOOL)forMarkdownPreview
{
	[aMenu removeAllItems];

	std::map<std::string, std::multimap<std::string, bundles::item_ptr, text::less_t>> ordered;
	for(auto const& item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeTheme))
	{
		if(item->hidden_from_user())
			continue;

		auto semanticClass = text::split(item->value_for_field(bundles::kFieldSemanticClass), ".");
		std::string themeClass = semanticClass.size() > 2 && semanticClass.front() == "theme" ? semanticClass[1] : "unspecified";
		ordered[themeClass].emplace(item->name(), item);
	}

	if(ordered.empty())
	{
		[aMenu addItemWithTitle:@"No Themes Loaded" action:@selector(nop:) keyEquivalent:@""];
		return;
	}

	SEL const appearanceAction = forMarkdownPreview ? @selector(takeMarkdownPreviewThemeAppearanceFrom:)   : @selector(takeThemeAppearanceFrom:);
	SEL const lightAction      = forMarkdownPreview ? @selector(takeMarkdownPreviewUniversalThemeUUIDFrom:) : @selector(takeUniversalThemeUUIDFrom:);
	SEL const darkAction       = forMarkdownPreview ? @selector(takeMarkdownPreviewDarkThemeUUIDFrom:)      : @selector(takeDarkThemeUUIDFrom:);

	NSMenu* lightMenu;
	NSMenu* darkMenu;

	// The editor menu’s Auto stores nil (key removed); the preview’s stores an
	// explicit "auto", since for the preview an absent key means something
	// else — follow the editor’s appearance setting.
	MBMenu items = {
		{ @"Appearance",       @selector(nop:),                                                                    },
		{ @"Light",            appearanceAction, .indent = 1, .target = self, .representedObject = @"light"        },
		{ @"Dark",             appearanceAction, .indent = 1, .target = self, .representedObject = @"dark"         },
		{ @"Auto",             appearanceAction, .indent = 1, .target = self, .representedObject = forMarkdownPreview ? @"auto" : nil },
		{ /* -------- */ },
		{ @"Theme for Light Appearance", .submenuRef = &lightMenu },
		{ @"Theme for Dark Appearance",  .submenuRef = &darkMenu  },
	};
	if(forMarkdownPreview)
	{
		items.insert(items.begin(), {
			{ @"Use Editor Theme", @selector(selectMarkdownPreviewEditorTheme:), .target = self },
			{ /* -------- */ },
		});
	}
	MBCreateMenu(items, aMenu);

	for(NSMenu* submenu : { lightMenu, darkMenu })
	{
		std::string skipThemeClass = submenu == lightMenu ? "dark" : "light";
		SEL action = submenu == lightMenu ? lightAction : darkAction;

		for(auto const& themeClasses : ordered)
		{
			if(themeClasses.first == skipThemeClass)
				continue;

			if(submenu.numberOfItems)
				[submenu addItem:[NSMenuItem separatorItem]];

			for(auto const& pair : themeClasses.second)
			{
				NSMenuItem* menuItem = [submenu addItemWithTitle:[NSString stringWithCxxString:pair.first] action:action keyEquivalent:@""];
				if(!forMarkdownPreview)
					[menuItem setKeyEquivalentCxxString:key_equivalent(pair.second)];
				[menuItem setRepresentedObject:[NSString stringWithCxxString:pair.second->uuid()]];
			}
		}
	}
}

- (void)themesMenuNeedsUpdate:(NSMenu*)aMenu
{
	[self buildThemesMenu:aMenu forMarkdownPreview:NO];
}

- (void)markdownPreviewThemesMenuNeedsUpdate:(NSMenu*)aMenu
{
	[self buildThemesMenu:aMenu forMarkdownPreview:YES];
}

- (void)spellingMenuNeedsUpdate:(NSMenu*)aMenu
{
	for(NSInteger i = aMenu.numberOfItems; i--; )
	{
		NSMenuItem* item = [aMenu itemAtIndex:i];
		if([item action] == @selector(takeSpellingLanguageFrom:))
			[aMenu removeItemAtIndex:i];
	}

	std::multimap<std::string, NSString*, text::less_t> ordered;

	NSSpellChecker* spellChecker = NSSpellChecker.sharedSpellChecker;
	for(NSString* lang in [spellChecker availableLanguages])
		ordered.emplace(to_s(NameForLocaleIdentifier(lang)), lang);

	NSString* systemSpellingLanguage = [spellChecker automaticallyIdentifiesLanguages] ? @"Automatic by Language" : NameForLocaleIdentifier([spellChecker language]);
	NSMenuItem* menuItem = [aMenu addItemWithTitle:[NSString stringWithFormat:@"System (%@)", systemSpellingLanguage] action:@selector(takeSpellingLanguageFrom:) keyEquivalent:@""];
	menuItem.representedObject = @"";

	for(auto const& it : ordered)
	{
		NSMenuItem* menuItem = [aMenu addItemWithTitle:[NSString stringWithCxxString:it.first] action:@selector(takeSpellingLanguageFrom:) keyEquivalent:@""];
		menuItem.representedObject = it.second;
	}
}

- (void)wrapColumnMenuNeedsUpdate:(NSMenu*)aMenu
{
	[aMenu removeAllItems];

	SEL action = @selector(takeWrapColumnFrom:);
	NSMenuItem* menuItem;

	menuItem = [aMenu addItemWithTitle:@"Use Window Frame" action:action keyEquivalent:@""];
	menuItem.tag = NSWrapColumnWindowWidth;
	[aMenu addItem:[NSMenuItem separatorItem]];

	NSArray* presets = [NSUserDefaults.standardUserDefaults arrayForKey:kUserDefaultsWrapColumnPresetsKey];
	for(NSNumber* preset in [presets sortedArrayUsingSelector:@selector(compare:)])
	{
		menuItem = [aMenu addItemWithTitle:[NSString stringWithFormat:@"%@", preset] action:action keyEquivalent:@""];
		menuItem.tag = [preset integerValue];
	}

	[aMenu addItem:[NSMenuItem separatorItem]];
	menuItem = [aMenu addItemWithTitle:@"Other…" action:action keyEquivalent:@""];
	menuItem.tag = NSWrapColumnAskUser;
}

- (void)menuNeedsUpdate:(NSMenu*)aMenu
{
	if(aMenu == bundlesMenu)
		[self bundlesMenuNeedsUpdate:aMenu];
	else if(aMenu == themesMenu)
		[self themesMenuNeedsUpdate:aMenu];
	else if(aMenu == markdownPreviewThemesMenu)
		[self markdownPreviewThemesMenuNeedsUpdate:aMenu];
	else if(aMenu == spellingMenu)
		[self spellingMenuNeedsUpdate:aMenu];
	else if(aMenu == wrapColumnMenu)
		[self wrapColumnMenuNeedsUpdate:aMenu];
}
@end
