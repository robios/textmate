#import "OakTextView_Private.h"
#import "OakTextView_LSPUtilities.h"
#import <lsp/LSPManager.h>
#import <Preferences/FormatterRegistry.h>
#import <Preferences/Keys.h>
#import <io/environment.h>
#include <atomic>

static NSString* runCustomFormatter (std::string const& command, NSString* inputText, std::map<std::string, std::string> const& variables, NSString** outError)
{
	NSTask* task = [[NSTask alloc] init];
	task.launchPath = @"/bin/sh";
	task.arguments = @[@"-c", [NSString stringWithCxxString:command]];

	NSMutableDictionary* env = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];

	auto const& tmEnv = oak::basic_environment();
	auto pathIt = tmEnv.find("PATH");
	if(pathIt != tmEnv.end())
		env[@"PATH"] = [NSString stringWithCxxString:pathIt->second];

	for(auto const& [key, value] : variables)
		env[[NSString stringWithCxxString:key]] = [NSString stringWithCxxString:value];

	task.environment = env;

	auto it = variables.find("TM_PROJECT_DIRECTORY");
	if(it == variables.end())
		it = variables.find("TM_DIRECTORY");
	if(it != variables.end())
		task.currentDirectoryURL = [NSURL fileURLWithPath:[NSString stringWithCxxString:it->second]];

	NSPipe* stdinPipe  = [NSPipe pipe];
	NSPipe* stdoutPipe = [NSPipe pipe];
	NSPipe* stderrPipe = [NSPipe pipe];

	task.standardInput  = stdinPipe;
	task.standardOutput = stdoutPipe;
	task.standardError  = stderrPipe;

	@try {
		[task launch];
	}
	@catch(NSException* e) {
		if(outError)
			*outError = [NSString stringWithFormat:@"Failed to launch formatter: %@", e.reason];
		return nil;
	}

	__block NSData* outputData = nil;
	__block NSData* errorData = nil;

	dispatch_group_t group = dispatch_group_create();
	dispatch_queue_t bgQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

	dispatch_group_async(group, bgQueue, ^{
		NSData* inputData = [inputText dataUsingEncoding:NSUTF8StringEncoding];
		[stdinPipe.fileHandleForWriting writeData:inputData];
		[stdinPipe.fileHandleForWriting closeFile];
	});

	dispatch_group_async(group, bgQueue, ^{
		outputData = [stdoutPipe.fileHandleForReading readDataToEndOfFile];
	});

	dispatch_group_async(group, bgQueue, ^{
		errorData = [stderrPipe.fileHandleForReading readDataToEndOfFile];
	});

	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
	while(task.isRunning && [deadline timeIntervalSinceNow] > 0)
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);

	if(task.isRunning)
	{
		[task terminate];
		[task waitUntilExit];
		dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC));
		if(outError)
			*outError = @"Formatter timed out";
		return nil;
	}

	dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

	NSString* errStr = errorData.length > 0 ? [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] : nil;
#ifndef NDEBUG
	if(errStr.length > 0)
		NSLog(@"[Formatter] stderr: %@", errStr);
#endif

	if(task.terminationStatus != 0)
	{
		if(outError)
			*outError = [errStr componentsSeparatedByString:@"\n"].firstObject ?: @"Formatter failed";
		return nil;
	}

	NSString* output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];

	if(!output || output.length == 0)
	{
		if(outError)
			*outError = @"Formatter returned empty output";
		return nil;
	}

	return output;
}

@implementation OakTextView (Formatting)

- (void)performFormatOnSave
{
	if(!documentView)
		return;

	OakDocument* doc = self.document;
	if(!doc)
		return;

	std::string filePath  = to_s(doc.path ?: @"");
	std::string fileType  = to_s(doc.fileType ?: @"");
	std::string directory = to_s(doc.directory ?: [doc.path stringByDeletingLastPathComponent] ?: @"");

	settings_t const settings = settings_for_path(filePath, fileType, directory);
	bool formatOnSave    = settings.get(kSettingsFormatOnSaveKey, false);
	bool lspFormatOnSave = settings.get("lspFormatOnSave", false);

	// Custom formatter on save: explicit formatCommand or auto-detected
	if(formatOnSave)
	{
		std::string formatCommand = settings.get(kSettingsFormatCommandKey, "");
		if(formatCommand.empty())
		{
			NSString* autoCommand = [[FormatterRegistry sharedInstance] formatCommandForPath:doc.path];
			if(autoCommand)
				formatCommand = to_s(autoCommand);
		}

		if(!formatCommand.empty())
		{
			NSString* inputText = [NSString stringWithCxxString:documentView->substr()];
			std::map<std::string, std::string> variables = [self variables];

			NSString* error = nil;
			NSString* output = runCustomFormatter(formatCommand, inputText, variables, &error);

			if(output && ![output isEqualToString:inputText])
			{
				size_t caretOffset = documentView->ranges().last().last.index;
				size_t newLength = to_s(output).size();

				AUTO_REFRESH;
				std::multimap<std::pair<size_t, size_t>, std::string> replacements;
				replacements.emplace(std::make_pair((size_t)0, documentView->size()), to_s(output));
				documentView->perform_replacements(replacements);
				documentView->set_ranges(ng::range_t(std::min(caretOffset, newLength)));
				_lastFormatterError = nil;
			}
			else if(error)
			{
				if(![error isEqualToString:_lastFormatterError])
				{
					_lastFormatterError = error;
					[self showToolTip:[NSString stringWithFormat:@"Formatter: %@", error]];
				}
				NSLog(@"[Formatter] Format-on-save failed: %@", error);
			}
		}
	}

	// LSP format on save (independent setting)
	if(lspFormatOnSave && [[LSPManager sharedManager] serverSupportsFormattingForDocument:doc])
	{
		[[LSPManager sharedManager] flushPendingChangesForDocument:doc];

		auto done = std::make_shared<std::atomic<bool>>(false);
		__block NSArray<NSDictionary*>* receivedEdits = nil;

		[[LSPManager sharedManager] requestFormattingForDocument:doc
			tabSize:doc.tabSize insertSpaces:doc.softTabs
			completion:^(NSArray<NSDictionary*>* edits) {
				receivedEdits = edits;
				done->store(true, std::memory_order_release);
			}];

		NSDate* timeout = [NSDate dateWithTimeIntervalSinceNow:0.5];
		while(!done->load(std::memory_order_acquire) && [timeout timeIntervalSinceNow] > 0)
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);

		if(!done->load(std::memory_order_acquire))
		{
			NSLog(@"[LSP] Format-on-save skipped: server did not respond within 500ms");
			return;
		}

		if(receivedEdits.count > 0)
		{
			AUTO_REFRESH;
			documentView->perform_replacements(replacementsFromTextEdits(*documentView, receivedEdits));
		}
	}
}

- (void)lspFormatDocument:(id)sender
{
	if(!documentView)
		return;

	OakDocument* doc = self.document;
	if(!doc)
		return;

	std::string filePath  = to_s(doc.path ?: @"");
	std::string fileType  = to_s(doc.fileType ?: @"");
	std::string directory = to_s(doc.directory ?: [doc.path stringByDeletingLastPathComponent] ?: @"");

	settings_t const settings = settings_for_path(filePath, fileType, directory);
	std::string formatCommand = settings.get(kSettingsFormatCommandKey, "");

	if(formatCommand.empty())
	{
		NSString* autoCommand = [[FormatterRegistry sharedInstance] formatCommandForPath:doc.path];
		if(autoCommand)
			formatCommand = to_s(autoCommand);
	}

	if(formatCommand.empty())
	{
#ifndef NDEBUG
		NSLog(@"[Formatter] No custom formatter found for %s", filePath.c_str());
#endif
		NSBeep();
		return;
	}

#ifndef NDEBUG
	NSLog(@"[Formatter] Running: %s", formatCommand.c_str());
#endif

	NSString* inputText = [NSString stringWithCxxString:documentView->substr()];
	std::map<std::string, std::string> variables = [self variables];

	NSString* error = nil;
	NSString* output = runCustomFormatter(formatCommand, inputText, variables, &error);

	if(output && ![output isEqualToString:inputText])
	{
#ifndef NDEBUG
		NSLog(@"[Formatter] Applied changes");
#endif
		size_t caretOffset = documentView->ranges().last().last.index;
		size_t newLength = to_s(output).size();

		AUTO_REFRESH;
		std::multimap<std::pair<size_t, size_t>, std::string> replacements;
		replacements.emplace(std::make_pair((size_t)0, documentView->size()), to_s(output));
		documentView->perform_replacements(replacements);
		documentView->set_ranges(ng::range_t(std::min(caretOffset, newLength)));
	}
	else if(error)
	{
		NSLog(@"[Formatter] Error: %@", error);
		[self showToolTip:error];
	}
#ifndef NDEBUG
	else
	{
		NSLog(@"[Formatter] No changes needed");
	}
#endif
}

- (void)lspFormatOnly:(id)sender
{
	if(!documentView)
		return;

	OakDocument* doc = self.document;
	if(!doc)
		return;

	LSPManager* lsp = [LSPManager sharedManager];

	bool hasSelection = documentView->has_selection();
	ng::ranges_t capturedRanges = documentView->ranges();
	size_t revision = documentView->revision();
	NSUInteger tabSize = doc.tabSize;
	BOOL insertSpaces = doc.softTabs;

	if(hasSelection && [lsp serverSupportsRangeFormattingForDocument:doc])
	{
		[lsp flushPendingChangesForDocument:doc];

		ng::range_t sel = capturedRanges.last();
		text::pos_t startPos = documentView->convert(sel.min().index);
		text::pos_t endPos   = documentView->convert(sel.max().index);

		__weak OakTextView* weakSelf = self;
		[lsp requestRangeFormattingForDocument:doc
			startLine:startPos.line startCharacter:startPos.column
			endLine:endPos.line endCharacter:endPos.column
			tabSize:tabSize insertSpaces:insertSpaces
			completion:^(NSArray<NSDictionary*>* edits) {
				OakTextView* strongSelf = weakSelf;
				if(!strongSelf || !strongSelf->documentView)
					return;
				if(!edits || edits.count == 0)
					return;
				if(strongSelf->documentView->revision() != revision)
					return;

				AUTO_REFRESH;
				strongSelf->documentView->perform_replacements(replacementsFromTextEdits(*strongSelf->documentView, edits));
			}];
	}
	else if([lsp serverSupportsFormattingForDocument:doc])
	{
		[lsp flushPendingChangesForDocument:doc];

		__weak OakTextView* weakSelf = self;
		[lsp requestFormattingForDocument:doc
			tabSize:tabSize insertSpaces:insertSpaces
			completion:^(NSArray<NSDictionary*>* edits) {
				OakTextView* strongSelf = weakSelf;
				if(!strongSelf || !strongSelf->documentView)
					return;
				if(!edits || edits.count == 0)
					return;
				if(strongSelf->documentView->revision() != revision)
					return;

				AUTO_REFRESH;
				strongSelf->documentView->perform_replacements(replacementsFromTextEdits(*strongSelf->documentView, edits));
			}];
	}
	else
	{
		NSBeep();
	}
}

@end
