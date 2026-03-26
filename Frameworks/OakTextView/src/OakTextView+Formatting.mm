#import "OakTextView_Private.h"
#import "OakTextView_LSPUtilities.h"
#import <lsp/LSPManager.h>
#import <Preferences/FormatterRegistry.h>
#import <Preferences/Keys.h>

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
	bool formatOnSave = settings.get(kSettingsFormatOnSaveKey, settings.get("lspFormatOnSave", false));
	std::string formatCommand = settings.get(kSettingsFormatCommandKey, "");

	if(formatCommand.empty())
	{
		NSString* autoCommand = [[FormatterRegistry sharedInstance] formatCommandForPath:doc.path];
		if(autoCommand)
			formatCommand = to_s(autoCommand);
	}

	if(formatOnSave && !formatCommand.empty())
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
	else if(formatOnSave && [[LSPManager sharedManager] serverSupportsFormattingForDocument:doc])
	{
		[[LSPManager sharedManager] flushPendingChangesForDocument:doc];

		__block BOOL done = NO;
		__block NSArray<NSDictionary*>* receivedEdits = nil;

		[[LSPManager sharedManager] requestFormattingForDocument:doc
			tabSize:doc.tabSize insertSpaces:doc.softTabs
			completion:^(NSArray<NSDictionary*>* edits) {
				receivedEdits = edits;
				done = YES;
			}];

		NSDate* timeout = [NSDate dateWithTimeIntervalSinceNow:0.1];
		while(!done && [timeout timeIntervalSinceNow] > 0)
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);

		if(!done)
			NSLog(@"[LSP] Format-on-save skipped: server did not respond within 100ms");

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
		}
		else if(error)
		{
			[self showToolTip:error];
		}
		return;
	}

	LSPManager* lsp = [LSPManager sharedManager];

	bool hasSelection = documentView->has_selection();
	ng::ranges_t capturedRanges = documentView->ranges();
	size_t revision = documentView->revision();
	NSUInteger tabSize = doc.tabSize;
	BOOL insertSpaces = doc.softTabs;

	[lsp flushPendingChangesForDocument:doc];

	__weak OakTextView* weakSelf = self;

	if(hasSelection && [lsp serverSupportsRangeFormattingForDocument:doc])
	{
		ng::range_t sel = capturedRanges.last();
		text::pos_t startPos = documentView->convert(sel.min().index);
		text::pos_t endPos   = documentView->convert(sel.max().index);

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
