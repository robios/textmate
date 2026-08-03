#import <OakCommand/OakCommand.h>

// Stands in for DocumentWindowController / AppController in OakCommand's
// responder chain, recording what the terminal was handed.
//
// It lives in a header, definition and all, because gen_test wraps each test
// file's body in a namespace named after the file — where Objective-C
// declarations are not allowed — while hoisting its #includes out to global
// scope. Exactly one translation unit ever includes this.
@interface TerminalTargetStub : NSResponder
@property (nonatomic) BOOL accept;                 // whether a terminal takes the command
@property (nonatomic) NSInteger runCount;
@property (nonatomic) NSInteger prepareCount;
@property (nonatomic) NSInteger errorCount;
@property (nonatomic) NSString* scriptPath;
@property (nonatomic) NSString* directory;
@property (nonatomic) std::map<std::string, std::string> environment;
@end

@implementation TerminalTargetStub
- (instancetype)init { if(self = [super init]) _accept = YES; return self; }

// Answered so a command's environment is exactly what the test passed in — the
// default route would fold in .tm_properties and the bundle index.
- (void)updateEnvironment:(std::map<std::string, std::string>&)environment forCommand:(OakCommand*)command { }

- (void)prepareEnvironmentForTerminalCommand:(std::map<std::string, std::string>&)environment
{
	++_prepareCount;
	environment.emplace("PREPARED", "yes");
}

- (BOOL)runScriptInTerminal:(NSString*)scriptPath environment:(std::map<std::string, std::string> const&)environment workingDirectory:(NSString*)directory
{
	++_runCount;
	_scriptPath  = scriptPath;
	_directory   = directory;
	_environment = environment;
	return _accept;
}

- (BOOL)presentError:(NSError*)error { return ++_errorCount, YES; }
@end
