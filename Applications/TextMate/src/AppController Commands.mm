#import "AppController.h"
#import <DocumentWindow/DocumentWindowController.h>
#import <DocumentWindow/TerminalEnvironment.h>
#import <bundles/bundles.h>
#import <command/parser.h>
#import <command/runner.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <ns/ns.h>
#import <settings/settings.h>
#import <OakAppKit/NSAlert Additions.h>
#import <OakAppKit/OakToolTip.h>
#import <OakFoundation/NSString Additions.h>
#import <OakCommand/OakCommand.h>
#import <plist/uuid.h>
#import <HTMLOutputWindow/HTMLOutputWindow.h>

@implementation AppController (Commands)
- (void)performBundleItemWithUUIDStringFrom:(id)anArgument
{
	NSString* uuidString = [anArgument valueForKey:@"representedObject"];
	if(bundles::item_ptr item = bundles::lookup(to_s(uuidString)))
	{
		if(id delegate = [NSApp.keyWindow.delegate respondsToSelector:@selector(performBundleItem:)] ? NSApp.keyWindow.delegate : [NSApp targetForAction:@selector(performBundleItem:)])
			[delegate performBundleItem:item];
	}
}

- (void)performBundleItem:(bundles::item_ptr)item
{
	switch(item->kind())
	{
		case bundles::kItemTypeSnippet:
		{
			// TODO set language according to snippet’s scope selector

			OakDocument* doc = [OakDocumentController.sharedInstance untitledDocument];
			[doc loadModalForWindow:nil completionHandler:^(OakDocumentIOResult result, NSString* errorMessage, oak::uuid_t const& filterUUID){
				[OakDocumentController.sharedInstance showDocument:doc];
				if(DocumentWindowController* controller = [DocumentWindowController controllerForDocument:doc])
					[controller performBundleItem:item];
				[doc markDocumentSaved];
				[doc close];
			}];
		}
		break;

		case bundles::kItemTypeCommand:
		{
			OakCommand* command = [[OakCommand alloc] initWithBundleCommand:parse_command(item)];
			command.firstResponder = NSApp;
			[command executeWithInput:nil variables:item->bundle_variables() outputHandler:nil];
		}
		break;

		case bundles::kItemTypeGrammar:
		{
			OakDocument* doc = [OakDocumentController.sharedInstance untitledDocument];
			doc.fileType = to_ns(item->value_for_field(bundles::kFieldGrammarScope));
			[OakDocumentController.sharedInstance showDocument:doc];
		}
		break;
	}
}

// A command can be invoked with no document window in the responder chain (the
// Bundles menu at application level, above). For an in-process command that
// means a silent run in $TMPDIR, seen only through whatever its output
// placement does on exit — which for a launcher-style command is precisely the
// quietly-does-nothing failure runLocation exists to end.
//
// Falling back to an in-process run is tempting and wrong: the command’s
// outputLocation is whatever it was left at, so the fallback could paste a dev
// server’s stdout into the user’s document. So: make the window the command
// needed. Not a reinterpretation of the user’s intent — a window with a
// terminal tab in it is that intent, fulfilled.
- (BOOL)runScriptInTerminal:(NSString*)scriptPath environment:(std::map<std::string, std::string> const&)environment workingDirectory:(NSString*)directory
{
	OakDocument* doc = [OakDocumentController.sharedInstance untitledDocument];
	[OakDocumentController.sharedInstance showDocument:doc];

	DocumentWindowController* controller = [DocumentWindowController controllerForDocument:doc];
	if(!controller)
		return NO;

	// Normally the directory arrived as the user’s home, there being no project to
	// take it from — which is where an untitled window’s own terminal opens too.
	// A global .tm_properties naming an existing TM_DIRECTORY reaches here as that
	// instead, and deserves to win, so whatever arrived is forwarded unchanged.
	return [controller runScriptInTerminal:scriptPath environment:environment workingDirectory:directory];
}

// Answered here as well as by the window controller: at application level the
// environment is composed — and requiredCommands checked against it — before
// the window above exists, so whoever is in the responder chain at that moment
// has to add the terminal integrations. Both routes apply the same idempotent
// helper, which is what makes their overlap harmless.
- (void)prepareEnvironmentForTerminalCommand:(std::map<std::string, std::string>&)environment
{
	environment = TerminalEnvironmentByAddingExtras(environment);
}
@end
