#import <bundles/item.h>
#include <map>
#include <string>

@class OakDocument;

@interface DocumentWindowController : NSResponder
@property (nonatomic) NSWindow*                                  window;

@property (nonatomic) NSUUID*                                    identifier;
@property (nonatomic) NSString*                                  defaultProjectPath;
@property (nonatomic, readonly) NSString*                        projectPath; // effectiveProjectPath
@property (nonatomic, readonly) NSString*                        untitledSavePath;

@property (nonatomic, readonly) NSArray<OakDocument*>*           documents;
@property (nonatomic, readonly) OakDocument*                     selectedDocument;
@property (nonatomic) NSUInteger                                 selectedTabIndex;

@property (nonatomic) BOOL                                       fileBrowserVisible;
@property (nonatomic) id                                         fileBrowserHistory;
@property (nonatomic) CGFloat                                    fileBrowserWidth;

@property (nonatomic) BOOL                                       htmlOutputVisible;
@property (nonatomic) NSSize                                     htmlOutputSize;

@property (nonatomic) BOOL                                       terminalVisible;
@property (nonatomic) NSSize                                     terminalSize;

@property (nonatomic) BOOL                                       markdownPreviewVisible;
@property (nonatomic) NSSize                                     markdownPreviewSize;

+ (BOOL)restoreSession;
+ (void)disableSessionSave;
+ (void)enableSessionSave;
+ (BOOL)saveSessionIncludingUntitledDocuments:(BOOL)includeUntitled;
+ (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender;

- (void)showWindow:(id)sender;
- (void)close;

- (IBAction)newFolder:(id)sender;
- (IBAction)newDocumentInTab:(id)sender;
- (IBAction)newDocumentInDirectory:(id)sender;
- (IBAction)moveDocumentToNewWindow:(id)sender; // TODO Move to AppController
- (IBAction)mergeAllWindows:(id)sender;         // TODO Move to AppController

- (IBAction)goToRelatedFile:(id)sender;
- (IBAction)selectNextTab:(id)sender;
- (IBAction)selectPreviousTab:(id)sender;
- (IBAction)takeSelectedTabIndexFrom:(id)sender;
- (IBAction)toggleSticky:(id)sender;

- (NSPoint)positionForWindowUnderCaret;
- (void)performBundleItem:(bundles::item_ptr)anItem;
- (IBAction)toggleHTMLOutput:(id)sender;
- (IBAction)toggleTerminal:(id)sender;
- (IBAction)newTerminal:(id)sender;
- (IBAction)newClaudeCodeTerminal:(id)sender;
- (IBAction)newCodexTerminal:(id)sender;
- (IBAction)nextTerminal:(id)sender;
- (IBAction)previousTerminal:(id)sender;
- (IBAction)closeTerminal:(id)sender;
- (IBAction)toggleMarkdownPreview:(id)sender;

// Run a bundle command’s script in a terminal of its own (runLocation:
// terminal), reached from OakCommand through the responder chain. The
// environment is final — see the implementation — and the return value says
// whether a terminal accepted the command, which is how the caller tells this
// window apart from a context that owns no terminal at all.
- (BOOL)runScriptInTerminal:(NSString*)scriptPath environment:(std::map<std::string, std::string> const&)environment workingDirectory:(NSString*)directory;
- (void)prepareEnvironmentForTerminalCommand:(std::map<std::string, std::string>&)environment;

- (IBAction)moveFocus:(id)sender;

- (IBAction)performCloseTab:(id)sender;
- (IBAction)performCloseSplit:(id)sender;
- (IBAction)performCloseWindow:(id)sender;
- (IBAction)performCloseAllTabs:(id)sender;
- (IBAction)performCloseOtherTabsXYZ:(id)sender;
- (IBAction)performCloseTabsToTheRight:(id)sender;
- (IBAction)performCloseTabsToTheLeft:(id)sender;

- (IBAction)saveDocument:(id)sender;
- (IBAction)saveDocumentAs:(id)sender;
- (IBAction)saveAllDocuments:(id)sender;
// - (IBAction)revertDocumentToSaved:(id)sender;

// =============================
// = Opening Auxiliary Windows =
// =============================

- (IBAction)orderFrontFindPanel:(id)sender;
- (IBAction)orderFrontRunCommandWindow:(id)sender;
- (IBAction)goToFile:(id)sender;

// ==================
// = OakFileBrowser =
// ==================

- (IBAction)toggleFileBrowser:(id)sender;
- (IBAction)revealFileInProject:(id)sender;
- (IBAction)goToProjectFolder:(id)sender;

- (IBAction)goBack:(id)sender;
- (IBAction)goForward:(id)sender;
- (IBAction)goToParentFolder:(id)sender;
- (IBAction)goToComputer:(id)sender;
- (IBAction)goToHome:(id)sender;
- (IBAction)goToDesktop:(id)sender;
- (IBAction)goToFavorites:(id)sender;
- (IBAction)goToSCMDataSource:(id)sender;
- (IBAction)orderFrontGoToFolder:(id)sender;

// Used by AppController
+ (instancetype)controllerForDocument:(OakDocument*)aDocument;
@end
