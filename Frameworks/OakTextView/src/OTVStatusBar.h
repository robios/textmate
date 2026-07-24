@protocol OTVStatusBarDelegate <NSObject>
- (void)showBundleItemSelector:(NSPopUpButton*)popUpButton;
- (void)showSymbolSelector:(NSPopUpButton*)popUpButton;
@optional
- (void)showLSPStatusMenu:(NSPopUpButton*)popUpButton;
- (void)showCopilotStatusMenu:(NSPopUpButton*)popUpButton;
// Fill in the commits the review base can be set to. The bar knows what
// the base is called, never what it could be.
- (void)showReviewBaseMenu:(NSPopUpButton*)popUpButton;
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

// The commit the window reviews against — named at all times so a base
// other than HEAD cannot be forgotten (most likely exactly when the
// diff pane is closed and nothing else says so), and the control that
// changes it, since the bar is the one surface always on screen.
// `isHead` picks the quiet look; anything else stands out. nil/empty
// collapses it away, for a document with no repository to have a base
// in.
- (void)setReviewBaseName:(NSString*)aName isHead:(BOOL)isHead;
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
