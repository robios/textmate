#import <Cocoa/Cocoa.h>
#import <scm/gutter_diff.h>
#import <scm/git_query.h>

@class OakDocument;

// What a snapshot knows about the repo, beyond the hunks themselves.
typedef NS_ENUM(NSInteger, BufferDiffRepoState) {
	BufferDiffRepoStateNoRepository = 0, // no path, not in a git repo, or git unavailable
	BufferDiffRepoStateTooLarge,         // buffer beyond the diff size cap
	BufferDiffRepoStateReady,
};

// One recompute's worth of buffer-vs-base results, immutable. The four
// editor-world states (HEAD, index, disk, buffer) are captured as
// independent pairwise comparisons: hunks (buffer vs base),
// documentEdited (buffer vs disk), hasStagedChanges (index vs HEAD).
@interface BufferDiffSnapshot : NSObject
@property (nonatomic, readonly) uint64_t generation;
@property (nonatomic, readonly) BufferDiffRepoState repoState;
@property (nonatomic, readonly, getter = isTracked) BOOL tracked;   // path exists in the review base
@property (nonatomic, readonly) BOOL hasStagedChanges;
@property (nonatomic, readonly, getter = isDocumentEdited) BOOL documentEdited; // buffer ≠ disk at compute time
@property (nonatomic, readonly) NSString* repoRoot;                 // nil unless Ready/TooLarge
@property (nonatomic, readonly) NSString* baseRef;                  // "HEAD" or a commit sha
@property (nonatomic, readonly, getter = isBaseHead) BOOL baseHead;
@property (nonatomic, readonly) NSString* headCommit;               // nil before the first commit
@property (nonatomic, readonly) NSString* previousHeadCommit;       // last observed pre-move HEAD, nil until HEAD moves
- (std::string const&)bufferText;                                   // LF-normalized buffer the hunks index into
- (std::string const&)baseText;                                     // full base blob
- (scm::gutter_diff::hunks_t const&)hunks;                          // buffer vs base
- (std::vector<scm::git_query::commit_t> const&)recentCommits;      // newest first, for the base selector
@end

// Per-document-view diff engine for the git-native review surfaces.
// Recomputes buffer-vs-base hunks on a trailing debounce after buffer
// edits, and immediately on save / scm events; maintains the
// diff.added/modified/deleted document marks (gutter column, minimap)
// against HEAD regardless of the review base — except on an untracked
// file, which publishes hunks but no marks at all, since every one of
// its lines is trivially added. Git subprocess state — staged check,
// HEAD commit, recent commits — is cached and refreshed only on scm
// events, document switches and saves, never on the buffer debounce
// (buffer edits cannot change the index).
@interface BufferDiffService : NSObject
@property (nonatomic) OakDocument* document;

// Review base ref; nil means HEAD. Setting it triggers a recompute.
// `repoRoot` is the repository the ref belongs to: a sha means nothing
// in another repository, so once the document moves outside it the base
// falls back to HEAD rather than resolving to nothing and reporting the
// whole file as untracked. nil root = applies anywhere.
- (void)setBaseRef:(NSString*)aRef forRepoRoot:(NSString*)aRepoRoot;
@property (nonatomic, readonly) NSString* baseRef;

// Called on the main queue with each fresh snapshot (stale results are
// dropped, never delivered out of order).
@property (nonatomic, copy) void (^snapshotHandler)(BufferDiffSnapshot* snapshot);

// Called on the main queue when the repo's HEAD is observed to move
// while attached. isDescendant is `git merge-base --is-ancestor old new`
// — a commit landed on top of the old HEAD (vs branch switch / reset).
@property (nonatomic, copy) void (^headMovedHandler)(NSString* oldHead, NSString* newHead, BOOL isDescendant);

- (void)scheduleUpdate; // debounced buffer-edit path
- (void)updateNow;      // immediate recompute, refreshing cached git state
@end
