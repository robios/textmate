@protocol OTVStatusBarDelegate <NSObject>
- (void)showBundleItemSelector:(NSPopUpButton*)popUpButton;
- (void)showSymbolSelector:(NSPopUpButton*)popUpButton;
@optional
- (void)showLSPStatusMenu:(NSPopUpButton*)popUpButton;
- (void)showCopilotStatusMenu:(NSPopUpButton*)popUpButton;
@end

@interface OTVStatusBar : NSVisualEffectView
- (void)showBundlesMenu:(id)sender;
// enabled controls the indicator's visibility (the global lspEnabled master
// switch); status nil while enabled renders the dimmed idle look. serverName
// only feeds the tooltip — the full status lives there.
- (void)setLspEnabled:(BOOL)enabled status:(NSString*)status serverName:(NSString*)serverName errors:(NSUInteger)errors warnings:(NSUInteger)warnings info:(NSUInteger)info;
- (void)flashLspError;
- (void)setCopilotStatus:(NSInteger)status;
@property (nonatomic) NSString* agentStatusText; // discreet agent-related note; nil/empty hides it
@property (nonatomic) NSString* selectionString;
@property (nonatomic) NSString* grammarName;
@property (nonatomic) NSString* symbolName;
@property (nonatomic) NSString* fileType; // This will update grammarName
@property (nonatomic, getter = isRecordingMacro) BOOL recordingMacro;
@property (nonatomic) BOOL softTabs;
@property (nonatomic) NSUInteger tabSize;

@property (nonatomic, weak) id <OTVStatusBarDelegate> delegate;
@property (nonatomic, weak) id target;
@end
