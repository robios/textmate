#import "BufferDiffService.h"
#import <document/OakDocument.h>
#import <scm/scm.h>
#import <io/path.h>
#import <settings/settings.h>
#import <Preferences/Keys.h>
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
@property (nonatomic, readwrite) OakReviewBaseKind baseKind;
@property (nonatomic, readwrite) NSString* baseSpec;
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
@property (nonatomic) OakReviewBaseKind baseKind;
@property (nonatomic) NSString* baseSpec;
@property (nonatomic) NSString* baseRepoRoot; // set only for a pinned commit
@end

@implementation BufferDiffService
{
	dispatch_queue_t _queue;
	std::atomic<uint64_t> _generation;

	NSTimer* _debounceTimer;

	scm::info_ptr _scmInfo;
	std::string   _scmInfoDirectory; // what _scmInfo was registered for

	// Bumped whenever this service starts speaking for a different
	// place. Document identity alone cannot carry that: a Save As
	// moves the SAME document into another repository, and anything
	// queued about the old one stops being true the moment it does.
	uint64_t _attachment;

	// Compute-queue-only state: the cached git-subprocess results and
	// the HEAD tracking used for the HEAD-moved banner. Buffer edits
	// never touch these — only scm events, saves and document switches
	// raise _repoStateRefreshNeeded, which the compute block consumes.
	std::string _cachedStateRoot;
	std::string _cachedStateRel;
	bool        _cachedStaged;
	std::string _cachedHead;          // NULL_STR before first refresh / unborn HEAD
	std::string _cachedBranch;        // symbolic HEAD, NULL_STR when detached
	std::string _previousHead;        // pre-move HEAD once a move was seen
	std::vector<scm::git_query::commit_t> _cachedRecentCommits;
	size_t      _cachedCommitLimit;   // what _cachedRecentCommits was asked for

	// What a relative spec last resolved to, and what it was resolved
	// from. A NULL_STR sha means the spec names nothing here — a
	// repository with fewer commits than it reaches back over.
	std::string _cachedRelativeRoot;
	std::string _cachedRelativeSpec;
	std::string _cachedRelativeSha;

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
		_attachment = 0;
		_cachedHead = NULL_STR;
		_cachedBranch = NULL_STR;
		_previousHead = NULL_STR;
		_cachedRelativeSha = NULL_STR;
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

// Whether an observation made about a repository is still about where
// this service is. Both halves are needed and neither implies the other:
// a tab switch changes the document while a Save As keeps it and changes
// the repository under it.
//
// Deliberately NOT the snapshot generation, which guards a different
// thing. A snapshot is a result, made stale by anything that changes its
// inputs; a HEAD move is an observation about a repository, which an
// edit, a save or a review-base change leave true even as they bump the
// generation. Dropping on generation would lose the notice for good,
// since the move is recorded into the cached HEAD before the callback is
// queued and no later recompute finds it again.
- (BOOL)isStillObserving:(OakDocument*)aDocument attachment:(uint64_t)anAttachment
{
	return aDocument == _document && anAttachment == _attachment;
}

- (void)registerSCMObserver
{
	NSString* path = _document.path;
	if(!path.length)
	{
		if(_scmInfo || !_scmInfoDirectory.empty())
			++_attachment; // there was a repository and now there is not
		_scmInfo.reset();
		_scmInfoDirectory.clear();
		return;
	}

	std::string const directory = path::parent(to_s(path));
	if(_scmInfo && directory == _scmInfoDirectory)
		return; // already watching the right place

	++_attachment; // past here this service speaks for a different place
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

- (void)setBaseKind:(OakReviewBaseKind)aKind spec:(NSString*)aSpec repoRoot:(NSString*)aRepoRoot
{
	NSString* newSpec = aSpec.length ? aSpec : nil;
	if(_baseKind == aKind && (_baseSpec == newSpec || [_baseSpec isEqualToString:newSpec]) && (_baseRepoRoot == aRepoRoot || [_baseRepoRoot isEqualToString:aRepoRoot]))
		return;
	_baseKind     = aKind;
	_baseSpec     = [newSpec copy];
	_baseRepoRoot = [aRepoRoot copy];

	// A relative spec has to be resolved against the repository before the
	// diff can run, and the resolution lives with the other cached git
	// state, which only a state refresh recomputes.
	if(aKind == OakReviewBaseKindRelative)
		_repoStateRefreshNeeded = true;

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
	OakReviewBaseKind const wantKind = _baseKind;
	std::string const wantSpec = _baseSpec.length ? to_s(_baseSpec) : NULL_STR;
	std::string const wantRoot = _baseRepoRoot.length ? to_s(_baseRepoRoot) : NULL_STR;
	BOOL const documentEdited = doc.isDocumentEdited;
	uint64_t const attachment = _attachment;

	// Read here rather than on the compute queue: settings lookups walk
	// the .tm_properties chain, and everything else the block needs is
	// likewise sampled on the main thread.
	settings_t const settings = settings_for_path(to_s(doc.virtualPath ?: path), to_s(doc.fileType), to_s(doc.directory ?: [path stringByDeletingLastPathComponent]));
	size_t const commitLimit = std::clamp<int32_t>(settings.get(kSettingsReviewBaseCommitLimitKey, kReviewBaseCommitLimitDefault), 0, kReviewBaseCommitLimitMax);

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

		// The base as an actual commit. Everything downstream — the blob
		// cache, the hunks, the revert labels — sees only what comes out
		// of here, so a spec whose meaning moves cannot leak into a cache
		// key or onto a button.
		//
		// Both non-HEAD kinds can fail to name a commit here, and both
		// fall back to HEAD rather than to nothing: a pinned sha carried
		// into another repository would resolve to nothing and report the
		// whole file as added, and a relative spec reaches back past the
		// first commit in a young repository.
		std::string refStr = "HEAD";
		OakReviewBaseKind kindInEffect = OakReviewBaseKindHead;
		if(root == NULL_STR || wantSpec == NULL_STR)
		{
			// No repository to resolve in, or nothing to resolve.
		}
		else if(wantKind == OakReviewBaseKindRelative)
		{
			// Resolved on the git-state cadence, never on the buffer
			// debounce: a keystroke cannot move HEAD, and this is a
			// subprocess.
			if(refreshRepoState || root != serviceForState->_cachedRelativeRoot || wantSpec != serviceForState->_cachedRelativeSpec)
			{
				serviceForState->_cachedRelativeSha  = scm::git_query::rev_parse(root, wantSpec);
				serviceForState->_cachedRelativeSpec = wantSpec;
				serviceForState->_cachedRelativeRoot = root;
			}

			if(serviceForState->_cachedRelativeSha != NULL_STR)
			{
				refStr       = serviceForState->_cachedRelativeSha;
				kindInEffect = OakReviewBaseKindRelative;
			}
		}
		else if(wantKind == OakReviewBaseKindCommit && wantRoot == root)
		{
			refStr       = wantSpec;
			kindInEffect = OakReviewBaseKindCommit;
		}

		snapshot.baseRef  = to_ns(refStr);
		snapshot.baseKind = kindInEffect;
		snapshot.baseSpec = kindInEffect == OakReviewBaseKindRelative ? to_ns(wantSpec) : nil;
		snapshot.baseHead = refStr == "HEAD"; // refined below, once the resolved HEAD is known

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
			if(refreshRepoState || root != serviceForState->_cachedStateRoot || rel != serviceForState->_cachedStateRel || commitLimit != serviceForState->_cachedCommitLimit)
			{
				std::string const head   = scm::git_query::head_commit(root);
				std::string const branch = scm::git_query::symbolic_head(root);

				// Ancestry only decides between a commit on this branch and a
				// rewrite of it, so a switch need not pay for the query.
				bool const sameRepo     = root == serviceForState->_cachedStateRoot;
				bool const sameBranch   = branch == serviceForState->_cachedBranch;
				bool const movedOnBranch = sameRepo && sameBranch && head != serviceForState->_cachedHead && serviceForState->_cachedHead != NULL_STR && head != NULL_STR;
				bool const isDescendant  = movedOnBranch && scm::git_query::is_ancestor(root, serviceForState->_cachedHead, head);
				auto const change = sameRepo ? scm::git_query::classify_head_change(serviceForState->_cachedBranch, serviceForState->_cachedHead, branch, head, isDescendant) : scm::git_query::head_change::none;

				if(change != scm::git_query::head_change::none)
				{
					std::string const oldHead = serviceForState->_cachedHead;
					serviceForState->_previousHead = oldHead;

					NSString* oldHeadNS = to_ns(oldHead);
					NSString* newHeadNS = to_ns(head);
					dispatch_async(dispatch_get_main_queue(), ^{
						BufferDiffService* strongSelf = weakSelf;
						// A released service answers NO here, which is the
						// right answer: there is nothing left to notify.
						if(![strongSelf isStillObserving:doc attachment:attachment])
							return;
						if(strongSelf.headMovedHandler)
							strongSelf.headMovedHandler(oldHeadNS, newHeadNS, change);
					});
				}
				else if(root != serviceForState->_cachedStateRoot)
				{
					serviceForState->_previousHead = NULL_STR; // new repo — old tracking is meaningless
				}

				serviceForState->_cachedHead          = head;
				serviceForState->_cachedBranch        = branch;
				serviceForState->_cachedStaged        = scm::git_query::has_staged_changes(root, rel);
				serviceForState->_cachedRecentCommits = commitLimit ? scm::git_query::recent_commits(root, commitLimit) : std::vector<scm::git_query::commit_t>();
				serviceForState->_cachedStateRoot     = root;
				serviceForState->_cachedStateRel      = rel;
				serviceForState->_cachedCommitLimit   = commitLimit;
			}

			snapshot.repoRoot         = to_ns(root);
			snapshot.hasStagedChanges = serviceForState->_cachedStaged;
			snapshot.headCommit       = serviceForState->_cachedHead != NULL_STR ? to_ns(serviceForState->_cachedHead) : nil;
			snapshot.previousHeadCommit = serviceForState->_previousHead != NULL_STR ? to_ns(serviceForState->_previousHead) : nil;
			[snapshot setRecentCommits:serviceForState->_cachedRecentCommits];

			// Choosing the commit HEAD already points at IS choosing HEAD.
			// The selector offers commits by sha, so comparing the ref as
			// a string calls that an older base: an unmodified file then
			// reads "Buffer matches <sha>" instead of "No uncommitted
			// changes", and the revert controls dress themselves as a
			// restore-to-past-version. Both shas are full ones — `git
			// rev-parse HEAD` and `git log --pretty=%H` — so they compare
			// directly.
			bool const baseIsHead = refStr == "HEAD" || (serviceForState->_cachedHead != NULL_STR && refStr == serviceForState->_cachedHead);
			snapshot.baseHead = baseIsHead;
			if(baseIsHead)
			{
				// Same reasoning one step further: a base that lands on HEAD
				// IS HEAD, so it must not go on describing itself as a pinned
				// commit either — the status bar would name a sha and mark
				// itself as an older base while showing the current one.
				snapshot.baseKind = OakReviewBaseKindHead;
				snapshot.baseSpec = nil;
			}

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
				//
				// Otherwise the marks ARE the hunks the pane is showing.
				// Gutter, minimap and pane all answer to the review base, so
				// a change means the same thing wherever the reader looks,
				// and one xdiff pass serves all three.
				if(!tracked)
						marks.clear();
				else	marks = scm::gutter_diff::marks_for_hunks(hunks);
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
