#import "OakTextView_Private.h"
#import "OakTextView_LSPUtilities.h"
#import <lsp/LSPManager.h>
#import <lsp/LSPClient.h>
#import <theme/OakTheme.h>
#import <parse/parse.h>
#import <parse/grammar.h>
#import <text/utf16.h>
#import <bundles/bundles.h>


@implementation OakTextView (Hover)

- (void)lspShowHoverInfo:(id)sender
{
	if(!documentView)
		return;

	size_t caret = documentView->ranges().last().last.index;
	ng::index_t index(caret);
	[self lspRequestHoverAtIndex:index];
}

- (void)lspRequestHoverAtIndex:(ng::index_t)index
{
	if(!documentView)
		return;

	[self dismissLSPHoverPanel];

	OakDocument* doc = self.document;
	if(!doc)
		return;

	// dismissLSPHoverPanel above cancelled any dwell; claim the tooltip so a
	// dwell that takes over before the server answers wins over this request
	_lspTooltipOwner = OakTextViewTooltipOwnerCommand;
	NSInteger const generation = ++_lspTooltipGeneration;

	text::pos_t pos = documentView->convert(index.index);
	OakTooltipSection* diagnosticsSection = [self lspDiagnosticsSectionAtIndex:index];

	ng::range_t wordRange = ng::extend(*documentView, index, kSelectionExtendToWord).last();
	std::string word = documentView->substr(wordRange.min().index, wordRange.max().index);
	NSString* cacheKey = to_ns(word);

	if(_lspHoverCache && cacheKey.length > 0)
	{
		NSDictionary* cachedEntry = _lspHoverCache[cacheKey];
		if(cachedEntry)
		{
			NSDate* cachedAt = cachedEntry[@"_cachedAt"];
			if(cachedAt && -[cachedAt timeIntervalSinceNow] < 60.0)
			{
				OakTooltipContent* content = cachedEntry[@"content"];
				if(content && ![content isEqual:[NSNull null]])
				{
					ng::range_t wordRange = ng::extend(*documentView, index, kSelectionExtendToWord).last();
					CGRect wordRect = documentView->rect_for_range(wordRange.min().index, wordRange.max().index);
					[self showLSPHoverTooltipForIndex:index.index diagnostics:diagnosticsSection hover:content atRect:NSRectFromCGRect(wordRect)];
					_lspHoverHighlightRange = wordRange;
					[self setNeedsDisplayInRect:NSRectFromCGRect(wordRect)];

					return;
				}
			}
			else
			{
				[_lspHoverCache removeObjectForKey:cacheKey];
			}
		}
	}

	// The caret’s diagnostics are known locally: show them right away, and
	// re-show combined with the server’s hover content when (if) it arrives
	if(diagnosticsSection)
	{
		CGRect wordRect = documentView->rect_for_range(wordRange.min().index, wordRange.max().index);
		[self showLSPHoverTooltipForIndex:index.index diagnostics:diagnosticsSection hover:nil atRect:NSRectFromCGRect(wordRect)];
		_lspHoverHighlightRange = wordRange;
		[self setNeedsDisplayInRect:NSRectFromCGRect(wordRect)];
	}

	[[LSPManager sharedManager] flushPendingChangesForDocument:doc];

	__weak OakTextView* weakSelf = self;
	_lspHoverRequestId = [[LSPManager sharedManager] requestHoverForDocument:doc
		line:pos.line
		character:pos.column
		completion:^(NSDictionary* hover) {
			OakTextView* strongSelf = weakSelf;
			if(!strongSelf || !strongSelf->documentView || !hover)
				return;

			strongSelf->_lspHoverRequestId = 0;

			NSString* grammarScope = to_ns(strongSelf->documentView->file_type());
			OakTooltipContent* content = [strongSelf createTooltipContentFromHover:hover grammarScope:grammarScope];

			if(!strongSelf->_lspHoverCache)
				strongSelf->_lspHoverCache = [NSMutableDictionary new];
			if(cacheKey.length > 0)
			{
				if(strongSelf->_lspHoverCache.count >= 50)
				{
					NSString* oldestKey = nil;
					NSDate* oldestDate = [NSDate date];
					for(NSString* key in strongSelf->_lspHoverCache)
					{
						NSDate* date = strongSelf->_lspHoverCache[key][@"_cachedAt"];
						if(date && [date compare:oldestDate] == NSOrderedAscending)
						{
							oldestDate = date;
							oldestKey = key;
						}
					}
					if(oldestKey)
						[strongSelf->_lspHoverCache removeObjectForKey:oldestKey];
				}
				strongSelf->_lspHoverCache[cacheKey] = @{
					@"content": content ?: [NSNull null],
					@"_cachedAt": [NSDate date]
				};
			}

			// The response is cached either way, but the tooltip itself may belong
			// to a dwell — or to a newer request — by the time it arrives
			if(content && strongSelf->_lspTooltipGeneration == generation)
			{
				// Re-read the diagnostics rather than reusing the section captured
				// when the request went out: the server may have re-published since
				OakTooltipSection* currentDiagnostics = [strongSelf lspDiagnosticsSectionAtIndex:index];

				ng::range_t wordRange = ng::extend(*strongSelf->documentView, index, kSelectionExtendToWord).last();
				CGRect wordRect = strongSelf->documentView->rect_for_range(wordRange.min().index, wordRange.max().index);
				[strongSelf showLSPHoverTooltipForIndex:index.index diagnostics:currentDiagnostics hover:content atRect:NSRectFromCGRect(wordRect)];
				strongSelf->_lspHoverHighlightRange = wordRange;
				[strongSelf setNeedsDisplayInRect:NSRectFromCGRect(wordRect)];
			}
		}];
}

// MARK: - Diagnostics

// Read the payloads from the buffer, not from the manager’s raw dictionaries:
// the buffer’s ranges shift with edits, so between an edit and the server’s next
// publish the protocol line/column coordinates describe a different text. The
// severities stored here are already normalized to error/warning/note.
- (OakTooltipSection*)lspDiagnosticsSectionAtIndex:(ng::index_t)index
{
	if(!documentView)
		return nil;

	std::vector<ng::diagnostic_t> const hits = documentView->diagnostics_at(index.index);
	if(hits.empty())
		return nil;

	NSFont* font = [NSFont systemFontOfSize:11];
	NSDictionary* messageAttrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor labelColor] };
	NSDictionary* originAttrs  = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor secondaryLabelColor] };

	NSMutableAttributedString* text = [NSMutableAttributedString new];
	size_t worstSeverity = 3;
	for(auto const& diagnostic : hits)
	{
		worstSeverity = std::min(worstSeverity, diagnostic.severity);

		if(text.length)
			[text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:messageAttrs]];

		NSColor* dotColor = diagnostic.severity == 1 ? NSColor.systemRedColor : (diagnostic.severity == 2 ? NSColor.systemOrangeColor : NSColor.systemBlueColor);
		[text appendAttributedString:[[NSAttributedString alloc] initWithString:@"● " attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: dotColor }]];
		[text appendAttributedString:[[NSAttributedString alloc] initWithString:to_ns(diagnostic.message) attributes:messageAttrs]];

		NSString* source = to_ns(diagnostic.source);
		NSString* code   = to_ns(diagnostic.code);
		if(source.length || code.length)
		{
			NSString* origin = source.length && code.length ? [NSString stringWithFormat:@"  %@(%@)", source, code] : [NSString stringWithFormat:@"  %@", source.length ? source : code];
			[text appendAttributedString:[[NSAttributedString alloc] initWithString:origin attributes:originAttrs]];
		}
	}

	NSString* label = hits.size() > 1 ? @"Diagnostics" : (worstSeverity == 1 ? @"Error" : (worstSeverity == 2 ? @"Warning" : @"Note"));
	return [[OakTooltipSection alloc] initWithLabel:label content:text];
}

// MARK: - Dwell (mouse hover over a squiggle)

// The byte range of whichever diagnostics cover the index — the union when
// severities overlap — so the dwell tooltip anchors to the squiggle and stays
// up while the pointer moves within it. Empty when the index is clean. This runs
// on every mouse-moved event, so it asks for the containing range per severity
// instead of copying the whole document’s diagnostics.
- (ng::range_t)lspDiagnosticRangeAtIndex:(size_t)index
{
	ng::range_t result;
	if(!documentView || !documentView->has_diagnostics())
		return result;

	for(size_t severity = 1; severity <= 3; ++severity)
	{
		auto range = documentView->diagnostic_range_containing(severity, index);
		if(range.first == range.second)
			continue;

		if(result.empty())
				result = ng::range_t(range.first, range.second);
		else	result = ng::range_t(std::min(result.min().index, range.first), std::max(result.max().index, range.second));
	}
	return result;
}

// The dwell target at a buffer index: the union of the non-empty diagnostic
// ranges covering it, or the index itself when a zero-width point marker sits
// there. ‘rect’ is what the pointer is tested against and what the tooltip
// anchors to — for a point that is the marker, which has no text extent of its
// own, so it gets the marker's width plus a little slop rather than a fake range.
- (BOOL)lspDiagnosticTargetAtIndex:(size_t)index range:(ng::range_t&)range isPoint:(BOOL&)isPoint rect:(CGRect&)rect
{
	if(!documentView || !documentView->has_diagnostics())
		return NO;

	if(ng::range_t covering = [self lspDiagnosticRangeAtIndex:index]; !covering.empty())
	{
		range   = covering;
		isPoint = NO;
		rect    = documentView->rect_for_range(covering.min().index, covering.max().index);
		return YES;
	}

	if(documentView->has_diagnostic_point_at(index))
	{
		CGFloat const slop = 3;
		range   = ng::range_t(index, index);
		isPoint = YES;
		rect    = documentView->rect_for_range(index, index);
		rect    = CGRectMake(rect.origin.x - slop, rect.origin.y, ct::kDiagnosticPointWidth + 2*slop, rect.size.height);
		return YES;
	}

	return NO;
}

- (void)lspConsiderDiagnosticHoverAtPoint:(NSPoint)pos
{
	[_diagnosticDwellTimer invalidate];
	_diagnosticDwellTimer = nil;

	if(!documentView)
		return;

	ng::index_t index = documentView->index_at_point(NSPointToCGPoint(pos));

	ng::range_t range;
	BOOL isPoint = NO;
	CGRect rect  = CGRectZero;
	BOOL const overTarget = [self lspDiagnosticTargetAtIndex:index.index range:range isPoint:isPoint rect:rect] && NSPointInRect(pos, NSRectFromCGRect(rect));

	BOOL const dwellIsShowing = _lspHoverTooltip.isVisible && _lspTooltipOwner == OakTextViewTooltipOwnerDwell;
	if(overTarget)
	{
		// A coalesced/union range can cover different payload sets at different
		// indices (an inner diagnostic nested in an outer one, for example).
		// Keep the tooltip only while the pointer still resolves to the exact index
		// whose payloads it is showing. Re-arming is cheap; diagnostics_at() remains
		// deferred until the timer fires instead of returning to the mouse-moved path.
		if(dwellIsShowing && _lspTooltipIndex == index.index && _diagnosticHoverIsPoint == isPoint && _diagnosticHoverRange == range)
			return;

		// The index under the pointer, not the union range's start: nested and
		// overlapping diagnostics only all show up when the payloads are looked up
		// at the position the user is actually pointing at
		_diagnosticDwellTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 target:self selector:@selector(lspDiagnosticDwellTimerDidFire:) userInfo:@{ @"index": @(index.index) } repeats:NO];
	}
	else if(_diagnosticHoverIsPoint || !_diagnosticHoverRange.empty())
	{
		if(dwellIsShowing) // never dismiss a tooltip the hover command owns
			[_lspHoverTooltip dismiss];
		_diagnosticHoverRange   = ng::range_t();
		_diagnosticHoverIsPoint = NO;
	}
}

- (void)lspDiagnosticDwellTimerDidFire:(NSTimer*)timer
{
	_diagnosticDwellTimer = nil;
	if(!documentView)
		return;

	// The index the pointer was over. The union range is recomputed from it below
	// for the anchor; the payloads are read at the index itself.
	size_t index = [timer.userInfo[@"index"] unsignedIntegerValue];

	ng::range_t range;
	BOOL isPoint = NO;
	CGRect rect  = CGRectZero;
	if(![self lspDiagnosticTargetAtIndex:index range:range isPoint:isPoint rect:rect])
		return;

	// 0.35 s is long enough for the pointer to have left the squiggle without a
	// mouseMoved: telling us — it stops at the view boundary, and there is no
	// mouseExited: — and long enough for a click to have dismissed the popover,
	// which would otherwise pop back up on its own.
	if(!self.window || !NSPointInRect([self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil], NSRectFromCGRect(rect)))
		return;

	// A command tooltip already showing this very index says everything dwell
	// would, plus the server's hover sections. Taking it over would drop those and
	// cancel a request that is about to enrich it further.
	if(_lspHoverTooltip.isVisible && _lspTooltipOwner == OakTextViewTooltipOwnerCommand && _lspTooltipIndex == index)
		return;

	OakTooltipSection* section = [self lspDiagnosticsSectionAtIndex:ng::index_t(index)];
	if(!section)
		return;

	// Dwell takes the tooltip over: drop an outstanding command-hover request so
	// its answer cannot arrive later and replace this content
	[self cancelLSPHoverRequest];
	_lspTooltipOwner = OakTextViewTooltipOwnerDwell;
	++_lspTooltipGeneration;

	[self showLSPHoverTooltipForIndex:index diagnostics:section hover:nil atRect:NSRectFromCGRect(rect)];
	_diagnosticHoverRange   = range;
	_diagnosticHoverIsPoint = isPoint;
}

// A re-publish can replace a diagnostic's message without moving it. Whatever is
// on screen is stale at that point, and since nothing moved, neither a repaint nor
// pointer movement inside the same range would refresh it. So rebuild the local
// section from the buffer and re-show it, whichever surface owns the tooltip: the
// server's hover sections are carried over untouched, and the generation is left
// alone so an in-flight hover answer is still welcome when it lands.
//
// Re-presenting is not free — it installs a fresh hosting controller — so a
// publish that did not touch *this* index is ignored, and one that did preserves
// the selected tab. A diagnostics burst elsewhere in the file must not pull the
// reader off the Documentation tab.
//
// If the diagnostic is simply gone, the presentation path finds nothing to show
// and closes the tooltip — including, unavoidably, a command tooltip whose server
// answer has not arrived yet. Showing the old message instead is worse.
- (void)lspDiagnosticsDidChange
{
	if(!documentView || !_lspHoverTooltip.isVisible || _lspTooltipOwner == OakTextViewTooltipOwnerNone)
		return;

	if(documentView->diagnostics_at(_lspTooltipIndex) == _lspTooltipDiagnostics)
		return;

	NSRect rect = NSRectFromCGRect(_lspTooltipRect);
	if(_lspTooltipOwner == OakTextViewTooltipOwnerDwell)
	{
		// Dwell is anchored to the squiggle, which the publish may have reshaped —
		// or turned into a point, or removed from under the pointer entirely
		ng::range_t range;
		BOOL isPoint = NO;
		CGRect target = CGRectZero;
		if(![self lspDiagnosticTargetAtIndex:_lspTooltipIndex range:range isPoint:isPoint rect:target])
		{
			[_lspHoverTooltip dismiss];
			return;
		}

		rect                    = NSRectFromCGRect(target);
		_diagnosticHoverRange   = range;
		_diagnosticHoverIsPoint = isPoint;
	}

	[self showLSPHoverTooltipForIndex:_lspTooltipIndex diagnostics:[self lspDiagnosticsSectionAtIndex:ng::index_t(_lspTooltipIndex)] hover:_lspTooltipHoverContent atRect:rect preservingSelection:YES];
}

- (OakTooltipContent*)createTooltipContentFromHover:(NSDictionary*)hover grammarScope:(NSString*)grammarScope
{
	NSString* value = hover[@"value"];
	if(!value.length)
		return nil;

	NSString* kind = hover[@"kind"];
	NSString* language = hover[@"language"];
	BOOL isMarkdown = [kind isEqualToString:@"markdown"];

	NSMutableArray<OakTooltipSection*>* sections = [NSMutableArray new];

	if(isMarkdown)
	{
		// Extract code blocks for "Signature" section
		static NSRegularExpression* codeBlockRegex = [NSRegularExpression regularExpressionWithPattern:@"```(?:\\w+)?\\n([\\s\\S]*?)\\n```" options:0 error:nil];
		NSArray* codeMatches = [codeBlockRegex matchesInString:value options:0 range:NSMakeRange(0, value.length)];

		if(codeMatches.count > 0)
		{
			NSTextCheckingResult* firstMatch = codeMatches[0];
			NSString* signature = [value substringWithRange:[firstMatch rangeAtIndex:1]];
			signature = [signature stringByReplacingOccurrencesOfString:@"<?php\n" withString:@""];
			signature = [signature stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

			if(signature.length > 0)
			{
				NSAttributedString* highlighted = [self syntaxHighlight:signature withGrammar:grammarScope];
				[sections addObject:[[OakTooltipSection alloc] initWithLabel:@"Signature" content:highlighted]];
			}
		}

		// Remove code blocks to get remaining text
		NSMutableString* remaining = [value mutableCopy];
		for(NSTextCheckingResult* match in [codeMatches reverseObjectEnumerator])
			[remaining replaceCharactersInRange:[match rangeAtIndex:0] withString:@""];
		NSString* bodyText = [remaining stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

		if(bodyText.length > 0)
		{
			// Deduplicate --- separated chunks, then merge into one Documentation section
			NSArray<NSString*>* chunks = [bodyText componentsSeparatedByString:@"\n---\n"];
			NSMutableArray<NSString*>* uniqueChunks = [NSMutableArray new];
			NSMutableSet<NSString*>* seen = [NSMutableSet new];

			for(NSString* chunk in chunks)
			{
				NSString* trimmed = [chunk stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				if(trimmed.length > 0 && ![seen containsObject:trimmed])
				{
					[seen addObject:trimmed];
					[uniqueChunks addObject:trimmed];
				}
			}

			NSString* merged = [uniqueChunks componentsJoinedByString:@"\n\n"];
			if(merged.length > 0)
			{
				NSAttributedString* parsed = [self parseMarkdownToAttributedString:merged];
				if(parsed.length > 0)
					[sections addObject:[[OakTooltipSection alloc] initWithLabel:@"Documentation" content:parsed]];
			}
		}
	}
	else if(language)
	{
		NSAttributedString* highlighted = [self syntaxHighlight:value withGrammar:grammarScope];
		[sections addObject:[[OakTooltipSection alloc] initWithLabel:@"Signature" content:highlighted]];
	}
	else if(value.length > 0)
	{
		NSAttributedString* plainText = [[NSAttributedString alloc]
			initWithString:value
				attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11]}];
		[sections addObject:[[OakTooltipSection alloc] initWithLabel:@"Info" content:plainText]];
	}

	if(sections.count == 0)
		return nil;

	return [[OakTooltipContent alloc] initWithSections:sections];
}

// The one presentation point for the hover tooltip. The locally-derived
// diagnostics section is kept apart from the server's hover content — and both,
// with the index and anchor they were built for, are remembered — so a
// diagnostics re-publish can rebuild the local half in place instead of leaving a
// stale message on screen or throwing away the server's answer. Diagnostics come
// first because sections render as tabs.
- (void)showLSPHoverTooltipForIndex:(size_t)index diagnostics:(OakTooltipSection*)diagnosticsSection hover:(OakTooltipContent*)hoverContent atRect:(NSRect)rect
{
	[self showLSPHoverTooltipForIndex:index diagnostics:diagnosticsSection hover:hoverContent atRect:rect preservingSelection:NO];
}

- (void)showLSPHoverTooltipForIndex:(size_t)index diagnostics:(OakTooltipSection*)diagnosticsSection hover:(OakTooltipContent*)hoverContent atRect:(NSRect)rect preservingSelection:(BOOL)preservingSelection
{
	NSMutableArray<OakTooltipSection*>* sections = [NSMutableArray new];
	if(diagnosticsSection)
		[sections addObject:diagnosticsSection];
	if(hoverContent)
		[sections addObjectsFromArray:hoverContent.sections];

	if(sections.count == 0)
	{
		// Nothing left to say: a rebuild whose diagnostic is gone lands here
		if(_lspHoverTooltip.isVisible)
			[_lspHoverTooltip dismiss];
		return;
	}

	_lspTooltipIndex        = index;
	_lspTooltipRect         = NSRectToCGRect(rect);
	_lspTooltipHoverContent = hoverContent;
	_lspTooltipDiagnostics  = documentView ? documentView->diagnostics_at(index) : std::vector<ng::diagnostic_t>();

	[self showLSPHoverTooltip:[[OakTooltipContent alloc] initWithSections:sections] atRect:rect preservingSelection:preservingSelection];
}

- (void)showLSPHoverTooltip:(OakTooltipContent*)content atRect:(NSRect)rect
{
	[self showLSPHoverTooltip:content atRect:rect preservingSelection:NO];
}

- (void)showLSPHoverTooltip:(OakTooltipContent*)content atRect:(NSRect)rect preservingSelection:(BOOL)preservingSelection
{
	if(!content)
		return;

	OakThemeEnvironment* theme = [self lspTheme];

	if(!_lspHoverTooltip)
	{
		_lspHoverTooltip = [[OakInfoTooltip alloc] initWithTheme:theme];
		_lspHoverTooltip.delegate = (id<OakInfoTooltipDelegate>)self;
	}

	[_lspHoverTooltip showIn:self at:rect content:content preservingSelection:preservingSelection];
}



// MARK: - Dismiss

- (void)dismissLSPHoverPanel
{
	[self cancelLSPHoverRequest];
	[_diagnosticDwellTimer invalidate];
	_diagnosticDwellTimer = nil;
	_diagnosticHoverRange   = ng::range_t();
	_diagnosticHoverIsPoint = NO;
	_lspTooltipOwner = OakTextViewTooltipOwnerNone;
	++_lspTooltipGeneration;
	_lspTooltipHoverContent = nil;
	if(_lspHoverTooltip.isVisible)
	{
		[_lspHoverTooltip dismiss];
	}
	if(!_lspHoverHighlightRange.empty() && documentView)
	{
		[self setNeedsDisplayInRect:NSRectFromCGRect(documentView->rect_for_range(_lspHoverHighlightRange.min().index, _lspHoverHighlightRange.max().index))];
		_lspHoverHighlightRange = ng::range_t();
	}
}

// MARK: - Syntax Highlighting

// TextKit drops the leading whitespace of a line that does not fit the width it
// is laid out in, which flattens indented code onto the left margin in the
// narrow hover and completion panels. Carry the indentation as a paragraph
// indent instead: it survives wrapping, and continuation lines then line up
// under the code rather than under the margin.
static void ApplyCodeIndentation (NSMutableAttributedString* styled, NSFont* font, size_t tabSize)
{
	if(!styled.length)
		return;

	if(tabSize == 0)
		tabSize = 4;

	CGFloat const spaceWidth = [@" " sizeWithAttributes:@{ NSFontAttributeName: font }].width;
	NSString* str = [styled.string copy];

	std::vector<NSRange> lineRanges;
	for(NSUInteger index = 0; index < str.length; )
	{
		NSRange const lineRange = [str lineRangeForRange:NSMakeRange(index, 0)];
		lineRanges.push_back(lineRange);
		index = NSMaxRange(lineRange);
	}

	// Back-to-front: deleting a line's indentation must not shift the ranges
	// that have not been processed yet.
	for(auto it = lineRanges.rbegin(); it != lineRanges.rend(); ++it)
	{
		NSUInteger whitespaceLength = 0;
		CGFloat columns = 0;
		while(whitespaceLength < it->length)
		{
			unichar const ch = [str characterAtIndex:it->location + whitespaceLength];
			if(ch == ' ')
				columns += 1;
			else if(ch == '\t')
				columns = (floor(columns / tabSize) + 1) * tabSize;
			else
				break;
			++whitespaceLength;
		}

		NSMutableParagraphStyle* paragraphStyle = [NSMutableParagraphStyle new];
		paragraphStyle.lineBreakMode       = NSLineBreakByWordWrapping;
		paragraphStyle.firstLineHeadIndent  = columns * spaceWidth;
		paragraphStyle.headIndent           = columns * spaceWidth;

		if(whitespaceLength)
			[styled deleteCharactersInRange:NSMakeRange(it->location, whitespaceLength)];
		[styled addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:NSMakeRange(it->location, it->length - whitespaceLength)];
	}
}

- (NSMutableAttributedString*)syntaxHighlight:(NSString*)code withGrammar:(NSString*)grammarScope
{
	NSFont* baseFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];

	if(!grammarScope || code.length == 0)
	{
		NSDictionary* attrs = @{
			NSFontAttributeName: baseFont,
			NSForegroundColorAttributeName: [NSColor labelColor]
		};
		NSMutableAttributedString* plain = [[NSMutableAttributedString alloc] initWithString:code ?: @"" attributes:attrs];
		ApplyCodeIndentation(plain, baseFont, self.tabSize);
		return plain;
	}

	parse::grammar_ptr grammar;
	for(auto const& bundleItem : bundles::query(bundles::kFieldGrammarScope, to_s(grammarScope), scope::wildcard, bundles::kItemTypeGrammar))
	{
		if((grammar = parse::parse_grammar(bundleItem)))
			break;
	}

	OakTheme* theme = nil;
	if(bundles::item_ptr const& themeItem = bundles::lookup(to_s(self.themeUUID)))
		theme = [[OakTheme alloc] initWithBundleItem:themeItem];

	BOOL isPhp = [grammarScope isEqualToString:@"text.html.php"];
	static NSString* const phpPrefix = @"<?php\n";
	NSString* parseCode = (isPhp && ![code hasPrefix:@"<?"]) ? [phpPrefix stringByAppendingString:code] : code;
	NSUInteger prefixLen = (parseCode != code) ? phpPrefix.length : 0;

	NSDictionary* baseAttrs = @{
		NSFontAttributeName: baseFont,
		NSForegroundColorAttributeName: theme.foregroundColor ?: [NSColor labelColor]
	};
	NSMutableAttributedString* styled = [[NSMutableAttributedString alloc] initWithString:parseCode attributes:baseAttrs];

	if(grammar && theme)
	{
		std::string str = to_s(parseCode);
		std::map<size_t, scope::scope_t> allScopes;
		parse::stack_ptr parserState = grammar->seed();

		for(std::string::size_type i = 0; i != str.size(); )
		{
			auto eol = str.find('\n', i);
			eol = eol != std::string::npos ? ++eol : str.size();

			std::string line = str.substr(i, eol - i);
			std::map<size_t, scope::scope_t> lineScopes;
			parserState = parse::parse(line.data(), line.data() + line.size(), parserState, lineScopes, i == 0);

			for(auto const& pair : lineScopes)
				allScopes[i + pair.first] = pair.second;

			i = eol;
		}

		size_t from = 0, pos = 0;
		for(auto pair = allScopes.begin(); pair != allScopes.end(); )
		{
			OakThemeStyles* styles = [theme stylesForScope:pair->second];
			size_t to = ++pair != allScopes.end() ? pair->first : str.size();
			size_t len = utf16::distance(str.data() + from, str.data() + to);

			NSMutableDictionary* attrs = [NSMutableDictionary dictionary];
			attrs[NSForegroundColorAttributeName] = styles.foregroundColor;
			if(![styles.backgroundColor isEqual:theme.backgroundColor])
				attrs[NSBackgroundColorAttributeName] = styles.backgroundColor;
			if(styles.fontTraits)
				[styled applyFontTraits:styles.fontTraits range:NSMakeRange(pos, len)];
			[styled addAttributes:attrs range:NSMakeRange(pos, len)];

			pos += len;
			from = to;
		}
	}

	if(prefixLen > 0)
		[styled deleteCharactersInRange:NSMakeRange(0, prefixLen)];

	ApplyCodeIndentation(styled, baseFont, self.tabSize);

	return styled;
}

- (NSAttributedString*)parseMarkdownToAttributedString:(NSString*)markdown
{
	NSFont* baseFont = [NSFont systemFontOfSize:11];
	NSFont* boldFont = [NSFont boldSystemFontOfSize:11];
	NSFont* headingFont = [NSFont boldSystemFontOfSize:12];
	NSFont* monoFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	NSColor* textColor = [NSColor labelColor];
	NSColor* dimColor = [NSColor secondaryLabelColor];
	NSColor* linkColor = [NSColor linkColor];

	NSMutableAttributedString* result = [[NSMutableAttributedString alloc] init];
	NSDictionary* baseAttrs = @{NSFontAttributeName: baseFont, NSForegroundColorAttributeName: textColor};

	NSArray* lines = [markdown componentsSeparatedByString:@"\n"];
	BOOL firstLine = YES;

	for(NSString* rawLine in lines)
	{
		NSString* line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

		if(line.length == 0)
		{
			if(!firstLine && result.length > 0)
				[result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:baseAttrs]];
			continue;
		}

		// Skip --- horizontal rules
		if([[line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-"]] length] == 0 && line.length >= 3)
			continue;

		// Skip symbol-name lines like __Foo\Bar__
		static NSRegularExpression* symbolNameRegex = [NSRegularExpression regularExpressionWithPattern:@"^_{1,2}[a-zA-Z_$\\\\][a-zA-Z0-9_$:\\\\]*_{1,2}$" options:0 error:nil];
		if([symbolNameRegex numberOfMatchesInString:line options:0 range:NSMakeRange(0, line.length)] > 0)
			continue;

		if(!firstLine)
			[result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:baseAttrs]];
		firstLine = NO;

		// Headings: ### text or ## text or # text
		if([line hasPrefix:@"#"])
		{
			NSString* headingText = line;
			while([headingText hasPrefix:@"#"])
				headingText = [headingText substringFromIndex:1];
			headingText = [headingText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			NSDictionary* headingAttrs = @{NSFontAttributeName: headingFont, NSForegroundColorAttributeName: textColor};
			[result appendAttributedString:[[NSAttributedString alloc] initWithString:headingText attributes:headingAttrs]];
			continue;
		}

		// List items: - text or * text (at line start)
		NSString* contentLine = line;
		if(([line hasPrefix:@"- "] || [line hasPrefix:@"* "]) && line.length > 2)
		{
			[result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\u2022 " attributes:baseAttrs]];
			contentLine = [line substringFromIndex:2];
		}

		NSMutableAttributedString* lineResult = [self parseInlineMarkdown:contentLine
			baseFont:baseFont boldFont:boldFont monoFont:monoFont
			textColor:textColor dimColor:dimColor linkColor:linkColor];

		[result appendAttributedString:lineResult];
	}

	NSCharacterSet* ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	while(result.length > 0 && [ws characterIsMember:[result.string characterAtIndex:0]])
		[result deleteCharactersInRange:NSMakeRange(0, 1)];
	while(result.length > 0 && [ws characterIsMember:[result.string characterAtIndex:result.length - 1]])
		[result deleteCharactersInRange:NSMakeRange(result.length - 1, 1)];

	return result;
}

- (NSMutableAttributedString*)parseInlineMarkdown:(NSString*)text
	baseFont:(NSFont*)baseFont boldFont:(NSFont*)boldFont monoFont:(NSFont*)monoFont
	textColor:(NSColor*)textColor dimColor:(NSColor*)dimColor linkColor:(NSColor*)linkColor
{
	NSMutableAttributedString* result = [[NSMutableAttributedString alloc] init];
	NSDictionary* baseAttrs = @{NSFontAttributeName: baseFont, NSForegroundColorAttributeName: textColor};
	NSDictionary* boldAttrs = @{NSFontAttributeName: boldFont, NSForegroundColorAttributeName: textColor};
	NSDictionary* codeAttrs = @{NSFontAttributeName: monoFont, NSForegroundColorAttributeName: textColor};
	NSDictionary* dimAttrs  = @{NSFontAttributeName: baseFont, NSForegroundColorAttributeName: dimColor};

	NSMutableString* cleaned = [text mutableCopy];
	[cleaned replaceOccurrencesOfString:@"<b>" withString:@"**" options:0 range:NSMakeRange(0, cleaned.length)];
	[cleaned replaceOccurrencesOfString:@"</b>" withString:@"**" options:0 range:NSMakeRange(0, cleaned.length)];
	[cleaned replaceOccurrencesOfString:@"<i>" withString:@"*" options:0 range:NSMakeRange(0, cleaned.length)];
	[cleaned replaceOccurrencesOfString:@"</i>" withString:@"*" options:0 range:NSMakeRange(0, cleaned.length)];
	static NSRegularExpression* htmlTagRegex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
	cleaned = [[htmlTagRegex stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@""] mutableCopy];

	NSUInteger i = 0;
	NSUInteger len = cleaned.length;

	while(i < len)
	{
		unichar ch = [cleaned characterAtIndex:i];

		// Inline code: `text`
		if(ch == '`')
		{
			NSRange closeRange = [cleaned rangeOfString:@"`" options:0 range:NSMakeRange(i + 1, len - i - 1)];
			if(closeRange.location != NSNotFound)
			{
				NSString* code = [cleaned substringWithRange:NSMakeRange(i + 1, closeRange.location - i - 1)];
				[result appendAttributedString:[[NSAttributedString alloc] initWithString:code attributes:codeAttrs]];
				i = closeRange.location + 1;
				continue;
			}
		}

		// Links: [text](url)
		if(ch == '[')
		{
			NSRange closeBracket = [cleaned rangeOfString:@"](" options:0 range:NSMakeRange(i + 1, len - i - 1)];
			if(closeBracket.location != NSNotFound)
			{
				NSUInteger urlStart = closeBracket.location + 2;
				if(urlStart < len)
				{
					NSRange closeParen = [cleaned rangeOfString:@")" options:0 range:NSMakeRange(urlStart, len - urlStart)];
					if(closeParen.location != NSNotFound)
					{
						NSString* linkText = [cleaned substringWithRange:NSMakeRange(i + 1, closeBracket.location - i - 1)];
						NSString* urlString = [cleaned substringWithRange:NSMakeRange(urlStart, closeParen.location - urlStart)];
						NSMutableDictionary* linkAttrs = [NSMutableDictionary dictionaryWithDictionary:@{
							NSFontAttributeName: baseFont,
							NSForegroundColorAttributeName: linkColor,
							NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)
						}];
						NSURL* url = [NSURL URLWithString:urlString];
						if(url)
							linkAttrs[NSLinkAttributeName] = url;
						[result appendAttributedString:[[NSAttributedString alloc] initWithString:linkText attributes:linkAttrs]];
						i = closeParen.location + 1;
						continue;
					}
				}
			}
		}

		// Bold: **text**
		if(ch == '*' && i + 1 < len && [cleaned characterAtIndex:i + 1] == '*')
		{
			NSRange closeRange = [cleaned rangeOfString:@"**" options:0 range:NSMakeRange(i + 2, len - i - 2)];
			if(closeRange.location != NSNotFound)
			{
				NSString* bold = [cleaned substringWithRange:NSMakeRange(i + 2, closeRange.location - i - 2)];
				[result appendAttributedString:[[NSAttributedString alloc] initWithString:bold attributes:boldAttrs]];
				i = closeRange.location + 2;
				continue;
			}
		}

		// Italic: _text_
		if(ch == '_' && i + 1 < len && [cleaned characterAtIndex:i + 1] != '_'
			&& (i == 0 || [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[cleaned characterAtIndex:i - 1]]))
		{
			NSRange closeRange = [cleaned rangeOfString:@"_" options:0 range:NSMakeRange(i + 1, len - i - 1)];
			if(closeRange.location != NSNotFound
				&& (closeRange.location + 1 >= len || [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[cleaned characterAtIndex:closeRange.location + 1]]))
			{
				NSString* italic = [cleaned substringWithRange:NSMakeRange(i + 1, closeRange.location - i - 1)];
				[result appendAttributedString:[[NSAttributedString alloc] initWithString:italic attributes:dimAttrs]];
				i = closeRange.location + 1;
				continue;
			}
		}

		[result appendAttributedString:[[NSAttributedString alloc]
			initWithString:[NSString stringWithCharacters:&ch length:1] attributes:baseAttrs]];
		i++;
	}

	return result;
}

- (NSAttributedString*)parseMarkdownDocumentation:(NSString*)text
{
	NSArray* sections = [text componentsSeparatedByString:@"\n\n---\n\n"];
	if(sections.count > 1)
	{
		NSMutableArray* unique = [NSMutableArray new];
		NSMutableSet* seen = [NSMutableSet new];
		for(NSString* section in sections)
		{
			NSString* trimmed = [section stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if(trimmed.length > 0 && ![seen containsObject:trimmed])
			{
				[seen addObject:trimmed];
				[unique addObject:trimmed];
			}
		}
		text = [unique componentsJoinedByString:@"\n\n---\n\n"];
	}

	NSMutableAttributedString* combined = [[NSMutableAttributedString alloc] init];
	NSString* grammarScope = documentView ? to_ns(documentView->file_type()) : nil;

	static NSRegularExpression* codeBlockRegex = [NSRegularExpression regularExpressionWithPattern:@"```(\\w+)?\\n([\\s\\S]*?)\\n```" options:0 error:nil];
	NSArray* codeMatches = [codeBlockRegex matchesInString:text options:0 range:NSMakeRange(0, text.length)];

	NSString* bodyText = text;
	if(codeMatches.count > 0)
	{
		NSTextCheckingResult* firstMatch = codeMatches[0];
		NSString* signature = [text substringWithRange:[firstMatch rangeAtIndex:2]];
		signature = [signature stringByReplacingOccurrencesOfString:@"<?php\n" withString:@""];
		signature = [signature stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

		if(signature.length > 0)
			[combined appendAttributedString:[self syntaxHighlight:signature withGrammar:grammarScope]];

		NSMutableString* remaining = [text mutableCopy];
		for(NSTextCheckingResult* match in [codeMatches reverseObjectEnumerator])
			[remaining replaceCharactersInRange:[match rangeAtIndex:0] withString:@""];
		bodyText = [remaining stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		bodyText = [bodyText stringByReplacingOccurrencesOfString:@"---" withString:@""];
		bodyText = [bodyText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	}

	if(bodyText.length > 0)
	{
		if(combined.length > 0)
			[combined appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n" attributes:@{}]];

		if(codeMatches.count == 0)
			[combined appendAttributedString:[self syntaxHighlight:bodyText withGrammar:grammarScope]];
		else
			[combined appendAttributedString:[self parseMarkdownToAttributedString:bodyText]];
	}

	return combined.length > 0 ? combined : nil;
}

- (void)cancelLSPHoverRequest
{
	if(_lspHoverRequestId != 0)
	{
		[[LSPManager sharedManager] cancelRequest:_lspHoverRequestId forDocument:self.document];
		_lspHoverRequestId = 0;
	}
}

- (void)infoTooltipDidDismiss:(OakInfoTooltip*)tooltip
{
	// A click dismisses the popover on its own; an armed timer would bring it
	// straight back
	[_diagnosticDwellTimer invalidate];
	_diagnosticDwellTimer = nil;

	_diagnosticHoverRange   = ng::range_t();
	_diagnosticHoverIsPoint = NO;
	_lspTooltipOwner = OakTextViewTooltipOwnerNone;
	++_lspTooltipGeneration;
	_lspTooltipHoverContent = nil;
	if(!_lspHoverHighlightRange.empty() && documentView)
	{
		[self setNeedsDisplayInRect:NSRectFromCGRect(documentView->rect_for_range(_lspHoverHighlightRange.min().index, _lspHoverHighlightRange.max().index))];
		_lspHoverHighlightRange = ng::range_t();
	}
}

@end
