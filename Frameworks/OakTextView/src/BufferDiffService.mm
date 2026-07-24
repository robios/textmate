#import "BufferDiffService.h"
#import <document/OakDocument.h>
#import <scm/scm.h>
#import <io/path.h>
#import <text/types.h>
#import <ns/ns.h>
#import <atomic>

static NSTimeInterval const kBufferDiffDebounce = 0.2; // trailing, after buffer edits
static size_t const kBufferDiffMaxBytes = 2 * 1024 * 1024;

@interface BufferDiffSnapshot ()
{
	std::string _bufferText;
	std::string _baseText;
	scm::gutter_diff::hunks_t _hunks;
	std::vector<scm::git_query::commit_t> _recentCommits;
}
@property (nonatomic, readwrite) uint64_t generation;
@property (nonatomic, readwrite) BufferDiffRepoState repoState;
@property (nonatomic, readwrite, getter = isTracked) BOOL tracked;
@property (nonatomic, readwrite) BOOL hasStagedChanges;
@property (nonatomic, readwrite, getter = isDocumentEdited) BOOL documentEdited;
@property (nonatomic, readwrite) NSString* repoRoot;
@property (nonatomic, readwrite) NSString* baseRef;
@property (nonatomic, readwrite, getter = isBaseHead) BOOL baseHead;
@property (nonatomic, readwrite) NSString* headCommit;
@property (nonatomic, readwrite) NSString* previousHeadCommit;
@end

@implementation BufferDiffSnapshot
- (std::string const&)bufferText                              { return _bufferText; }
- (std::string const&)baseText                                { return _baseText; }
- (scm::gutter_diff::hunks_t const&)hunks                     { return _hunks; }
- (std::vector<scm::git_query::commit_t> const&)recentCommits { return _recentCommits; }

- (void)setBufferText:(std::string)text                              { _bufferText = std::move(text); }
- (void)setBaseText:(std::string)text                                { _baseText = std::move(text); }
- (void)setHunks:(scm::gutter_diff::hunks_t)hunks                    { _hunks = std::move(hunks); }
- (void)setRecentCommits:(std::vector<scm::git_query::commit_t>)list { _recentCommits = std::move(list); }
@end

@interface BufferDiffService ()
@property (nonatomic, readwrite) NSString* baseRef;
@property (nonatomic) NSString* baseRefRepoRoot; // the repository baseRef was picked in
@end

@implementation BufferDiffService
{
	dispatch_queue_t _queue;
	std::atomic<uint64_t> _generation;

	NSTimer* _debounceTimer;

	scm::info_ptr _scmInfo;
	std::string   _scmInfoDirectory; // what _scmInfo was registered for

	// Compute-queue-only state: the cached git-subprocess results and
	// the HEAD tracking used for the HEAD-moved banner. Buffer edits
	// never touch these — only scm events, saves and document switches
	// raise _repoStateRefreshNeeded, which the compute block consumes.
	std::string _cachedStateRoot;
	std::string _cachedStateRel;
	bool        _cachedStaged;
	std::string _cachedHead;          // NULL_STR before first refresh / unborn HEAD
	std::string _previousHead;        // pre-move HEAD once a move was seen
	std::vector<scm::git_query::commit_t> _cachedRecentCommits;

	// Raised on the main thread, consumed on the compute queue — and only
	// by a block that outlives the generation check, so a request cannot
	// be swallowed by a buffer edit that supersedes it mid-flight.
	std::atomic<bool> _repoStateRefreshNeeded;
}

- (id)init
{
	if(self = [super init])
	{
		_queue = dispatch_queue_create("com.macromates.buffer-diff", DISPATCH_QUEUE_SERIAL);
		_cachedHead = NULL_STR;
		_previousHead = NULL_STR;
	}
	return self;
}

- (void)dealloc
{
	[_debounceTimer invalidate];
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

// ============
// = Document =
// ============

- (void)setDocument:(OakDocument*)aDocument
{
	if(_document == aDocument)
		return;

	if(_document)
	{
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentContentDidChangeNotification object:_document];
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentDidSaveNotification object:_document];

		// Diff marks are derived state — recomputable from the buffer and
		// the base, and meaningless without them. The mark store is not:
		// closing a document copies every mark it carries into a
		// process-global tracker, which hands them back when the file is
		// reopened. Left alone these outlive the buffer they describe and
		// come back stale on the next open, ahead of the first recompute.
		//
		// Detaching is where they go, because it is the last moment this
		// service is still the document's. A close-time hook does not
		// work: closing a tab detaches the view first, so by the time the
		// close announces itself the observers are already gone.
		//
		// The cost is a second view onto the same document losing its
		// bars until its own next recompute. That case already has two
		// services writing one set of marks; it is rare and it heals on
		// the next edit, save or repository event.
		[self clearMarksFromDocument:_document];
	}

	_document = aDocument;
	_scmInfo.reset();
	_scmInfoDirectory.clear();

	if(_document)
	{
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentContentDidChange:) name:OakDocumentContentDidChangeNotification object:_document];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentDidSave:) name:OakDocumentDidSaveNotification object:_document];
		[self registerSCMObserver];
	}

	_repoStateRefreshNeeded = true;
	[self updateNow];
}

- (void)registerSCMObserver
{
	NSString* path = _document.path;
	if(!path.length)
	{
		_scmInfo.reset();
		_scmInfoDirectory.clear();
		return;
	}

	std::string const directory = path::parent(to_s(path));
	if(_scmInfo && directory == _scmInfoDirectory)
		return; // already watching the right place

	_scmInfoDirectory = directory;
	if(_scmInfo = scm::info(directory))
	{
		__weak BufferDiffService* weakSelf = self;
		_scmInfo->push_callback(^(scm::info_t const&){
			// Fires on every repo status update — commits, branch
			// switches, index changes — even when this file's own
			// status is unchanged.
			if(BufferDiffService* strongSelf = weakSelf)
			{
				strongSelf->_repoStateRefreshNeeded = true;
				[strongSelf updateNow];
			}
		});
	}
}

- (void)setBaseRef:(NSString*)aRef forRepoRoot:(NSString*)aRepoRoot
{
	NSString* newRef = aRef.length ? aRef : nil;
	if((_baseRef == newRef || [_baseRef isEqualToString:newRef]) && (_baseRefRepoRoot == aRepoRoot || [_baseRefRepoRoot isEqualToString:aRepoRoot]))
		return;
	_baseRef         = [newRef copy];
	_baseRefRepoRoot = [aRepoRoot copy];
	[self updateNow];
}

- (void)documentContentDidChange:(NSNotification*)aNotification
{
	[self scheduleUpdate];
}

- (void)documentDidSave:(NSNotification*)aNotification
{
	// Save As can give an untitled document its first path, and can move a
	// document into a different repository — in which case the observer is
	// still watching the old one and would never report the new repo's
	// index or HEAD.
	[self registerSCMObserver];
	_repoStateRefreshNeeded = true;
	[self updateNow];
}

// ==========
// = Update =
// ==========

- (void)scheduleUpdate
{
	[_debounceTimer invalidate];
	_debounceTimer = [NSTimer scheduledTimerWithTimeInterval:kBufferDiffDebounce target:self selector:@selector(debounceDidFire:) userInfo:nil repeats:NO];
}

- (void)debounceDidFire:(NSTimer*)aTimer
{
	_debounceTimer = nil;
	[self updateNow];
}

- (void)clearMarksFromDocument:(OakDocument*)doc
{
	[doc removeAllMarksOfType:@"diff.added"];
	[doc removeAllMarksOfType:@"diff.modified"];
	[doc removeAllMarksOfType:@"diff.deleted"];
}

- (void)updateNow
{
	[_debounceTimer invalidate];
	_debounceTimer = nil;

	uint64_t const generation = ++_generation;
	OakDocument* doc = _document;

	NSString* const path = doc.path;
	if(!doc || !path.length)
	{
		[self clearMarksFromDocument:doc];
		BufferDiffSnapshot* snapshot = [BufferDiffSnapshot new];
		snapshot.generation = generation;
		snapshot.repoState  = BufferDiffRepoStateNoRepository;
		snapshot.baseRef    = @"HEAD";
		snapshot.baseHead   = YES;
		if(_snapshotHandler)
			_snapshotHandler(snapshot);
		return;
	}

	// Read on the main thread (it is the live buffer) but consumed on the
	// compute queue. Held by shared_ptr so the block captures a pointer
	// rather than a const copy of the string: `std::move` on a
	// block-captured local is silently a copy, and this can be megabytes
	// on every keystroke's recompute.
	auto const bufferTextPtr = std::make_shared<std::string>(to_s(doc.content ?: @""));
	std::string const pathStr  = to_s(path);
	std::string const wantRef  = _baseRef.length ? to_s(_baseRef) : "HEAD";
	std::string const wantRoot = _baseRefRepoRoot.length ? to_s(_baseRefRepoRoot) : NULL_STR;
	BOOL const documentEdited = doc.isDocumentEdited;

	__weak BufferDiffService* weakSelf = self;
	dispatch_async(_queue, ^{
		BufferDiffService* serviceForState = weakSelf;
		if(!serviceForState || generation != serviceForState->_generation)
			return; // superseded — leave _repoStateRefreshNeeded for the block that wins

		bool const refreshRepoState = serviceForState->_repoStateRefreshNeeded.exchange(false);

		BufferDiffSnapshot* snapshot = [BufferDiffSnapshot new];
		snapshot.generation     = generation;
		snapshot.documentEdited = documentEdited;

		scm::gutter_diff::result_t marks;
		bool marksValid = false;

		std::string const root = scm::root_for_path(pathStr);
		std::string const rel  = root != NULL_STR ? path::relative_to(pathStr, root) : NULL_STR;

		// A commit sha only means something inside the repository it was
		// picked from; carried into another one it resolves to nothing and
		// would report every line of the file as added.
		std::string const refStr = (wantRoot == NULL_STR || wantRoot == root) ? wantRef : "HEAD";
		snapshot.baseRef  = to_ns(refStr);
		snapshot.baseHead = refStr == "HEAD";

		if(root == NULL_STR || rel == NULL_STR || rel.empty())
		{
			snapshot.repoState = BufferDiffRepoStateNoRepository;
			marksValid = true; // explicitly empty — clears stale marks
		}
		else
		{
			// Cached git-subprocess state, refreshed only on scm events,
			// saves and document/repo switches — never on the buffer
			// debounce (buffer edits cannot change index or HEAD).
			if(refreshRepoState || root != serviceForState->_cachedStateRoot || rel != serviceForState->_cachedStateRel)
			{
				std::string const head = scm::git_query::head_commit(root);

				if(root == serviceForState->_cachedStateRoot && serviceForState->_cachedHead != NULL_STR && head != NULL_STR && head != serviceForState->_cachedHead)
				{
					std::string const oldHead = serviceForState->_cachedHead;
					bool const isDescendant = scm::git_query::is_ancestor(root, oldHead, head);
					serviceForState->_previousHead = oldHead;

					NSString* oldHeadNS = to_ns(oldHead);
					NSString* newHeadNS = to_ns(head);
					dispatch_async(dispatch_get_main_queue(), ^{
						BufferDiffService* strongSelf = weakSelf;
						if(strongSelf && strongSelf.headMovedHandler)
							strongSelf.headMovedHandler(oldHeadNS, newHeadNS, isDescendant);
					});
				}
				else if(root != serviceForState->_cachedStateRoot)
				{
					serviceForState->_previousHead = NULL_STR; // new repo — old tracking is meaningless
				}

				serviceForState->_cachedHead          = head;
				serviceForState->_cachedStaged        = scm::git_query::has_staged_changes(root, rel);
				serviceForState->_cachedRecentCommits = scm::git_query::recent_commits(root, 20);
				serviceForState->_cachedStateRoot     = root;
				serviceForState->_cachedStateRel      = rel;
			}

			snapshot.repoRoot         = to_ns(root);
			snapshot.hasStagedChanges = serviceForState->_cachedStaged;
			snapshot.headCommit       = serviceForState->_cachedHead != NULL_STR ? to_ns(serviceForState->_cachedHead) : nil;
			snapshot.previousHeadCommit = serviceForState->_previousHead != NULL_STR ? to_ns(serviceForState->_previousHead) : nil;
			[snapshot setRecentCommits:serviceForState->_cachedRecentCommits];

			if(bufferTextPtr->size() > kBufferDiffMaxBytes)
			{
				snapshot.repoState = BufferDiffRepoStateTooLarge;
				snapshot.tracked   = YES;
				marksValid = true; // beyond the cap the marks go away too
			}
			else
			{
				bool tracked = false;
				std::string baseText = scm::gutter_diff::blob_for_ref(root, refStr, rel, &tracked);

				snapshot.repoState = BufferDiffRepoStateReady;
				snapshot.tracked   = tracked;

				scm::gutter_diff::hunks_t hunks = scm::gutter_diff::hunks(baseText, *bufferTextPtr);

				// An untracked file publishes its hunks — reviewing a newly
				// created file is a core use case — but no line marks:
				// every line of it is trivially "added", so per-line
				// indication says nothing while turning gutter and minimap
				// solid green. "Untracked" is a file-level state, which the
				// file browser and the pane's empty state already carry.
				// Suppressing it at the one place marks are published
				// covers every consumer at once.
				if(!tracked)
				{
					marks.clear();
				}
				else if(refStr == "HEAD")
				{
					// Gutter/minimap marks always compare against HEAD; the
					// review base only drives the pane. One xdiff pass when
					// they coincide.
					marks = scm::gutter_diff::marks_for_hunks(hunks);
				}
				else
				{
					std::string const headText = scm::gutter_diff::blob_for_ref(root, "HEAD", rel);
					marks = scm::gutter_diff::marks_for_hunks(scm::gutter_diff::hunks(headText, *bufferTextPtr));
				}
				marksValid = true;

				[snapshot setBaseText:std::move(baseText)];
				[snapshot setHunks:std::move(hunks)];
			}
		}
		serviceForState = nil;

		[snapshot setBufferText:std::move(*bufferTextPtr)];

		dispatch_async(dispatch_get_main_queue(), ^{
			BufferDiffService* strongSelf = weakSelf;
			if(!strongSelf || generation != strongSelf->_generation)
				return;

			if(doc == strongSelf.document && marksValid)
			{
				[strongSelf clearMarksFromDocument:doc];
				for(auto const& pair : marks)
				{
					NSString* type = nil;
					switch(pair.second)
					{
						case scm::gutter_diff::change::added:    type = @"diff.added";    break;
						case scm::gutter_diff::change::modified: type = @"diff.modified"; break;
						case scm::gutter_diff::change::deleted:  type = @"diff.deleted";  break;
					}
					if(type)
						[doc setMarkOfType:type atPosition:text::pos_t(pair.first - 1, 0) content:nil];
				}
			}

			if(doc == strongSelf.document && strongSelf.snapshotHandler)
				strongSelf.snapshotHandler(snapshot);
		});
	});
}
@end
