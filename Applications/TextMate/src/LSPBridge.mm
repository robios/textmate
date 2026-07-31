#import "LSPBridge.h"
#import "OakSwiftUI-Swift.h"
#import <lsp/LSPClient.h>

@implementation LSPBridge

+ (void)toggleLogPanel
{
	[[OakLogPanel shared] toggle];
}

+ (void)setup
{
	static __unused LSPBridge* instance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		instance = [[LSPBridge alloc] init];
	});
}

- (instancetype)init
{
	if(self = [super init])
	{
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLog:) name:LSPLogNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleProgress:) name:LSPProgressNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleShowMessageRequest:) name:LSPShowMessageRequestNotification object:nil];
	}
	return self;
}

- (void)handleLog:(NSNotification*)note
{
	NSString* message = note.userInfo[@"message"];
	if(!message) return;

	NSNumber* type = note.userInfo[@"type"];
	int level = type ? type.intValue : 3; // Default to Info
	NSString* source = note.userInfo[@"source"] ?: @"LSP";
	NSString* server = note.userInfo[@"server"];
	if(server.length)
		message = [NSString stringWithFormat:@"[%@] %@", server, message];

	dispatch_async(dispatch_get_main_queue(), ^{
		[OakLogPanel.shared logWithMessage:message level:level source:source];
	});
}

- (void)handleShowMessageRequest:(NSNotification*)note
{
	NSString* message = [note.userInfo[@"message"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSNumber* type = note.userInfo[@"type"];
	NSArray<NSDictionary*>* actions = note.userInfo[@"actions"];
	NSArray<NSString*>* actionTitles = note.userInfo[@"actionTitles"];
	id requestId = note.userInfo[@"requestId"];
	LSPClient* client = (LSPClient*)note.object;

	if(!client || !requestId || requestId == [NSNull null])
		return;

	if(!message || !actionTitles || actionTitles.count == 0)
	{
		[client respondToShowMessageRequest:requestId action:nil];
		return;
	}

	int lspType = type ? type.intValue : 3;

	// window/showMessageRequest is a genuine modal question — the server
	// blocks on the reply — so it gets a real alert, not a toast. A sheet
	// dismissed by other means (window closing) answers nil, which the
	// protocol defines as “user dismissed”.
	dispatch_async(dispatch_get_main_queue(), ^{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.alertStyle = lspType == 1 ? NSAlertStyleCritical : NSAlertStyleWarning;
		alert.messageText = client.serverName.length ? client.serverName : @"Language Server";
		alert.informativeText = message;
		for(NSString* title in actionTitles)
			[alert addButtonWithTitle:title];

		void(^respond)(NSModalResponse) = ^(NSModalResponse returnCode){
			NSInteger index = returnCode - NSAlertFirstButtonReturn;
			NSDictionary* selectedAction = (index >= 0 && (NSUInteger)index < actions.count) ? actions[index] : nil;
			[client respondToShowMessageRequest:requestId action:selectedAction];
		};

		if(NSWindow* window = [NSApp mainWindow])
				[alert beginSheetModalForWindow:window completionHandler:respond];
		else	respond([alert runModal]);
	});
}

- (void)handleProgress:(NSNotification*)note
{
	// Progress is logged via LSPLogNotification; toasting is too noisy
	// for ephemeral operations like lint passes that complete instantly.
}

@end
