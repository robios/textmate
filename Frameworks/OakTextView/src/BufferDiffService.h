#import <Cocoa/Cocoa.h>
#import "OakReviewBase.h"
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
@property (nonatomic, readonly) NSString* documentPath;            // the document this was computed for; nil for an unsaved buffer
@property (nonatomic, readonly) NSString* baseRef;                  // "HEAD" or a commit sha — always resolved, never a spec
@property (nonatomic, readonly, getter = isBaseHead) BOOL baseHead;

// The base as it took effect here, which is not always the base that was
// asked for: a pinned sha carried into another repository, or a relative
// spec reaching back past the first commit, both come back as Head. Every
// surface reads these rather than the model, so none of them can claim a
// base the diff was not actually taken against.
@property (nonatomic, readonly) OakReviewBaseKind baseKind;
@property (nonatomic, readonly) NSString* baseSpec;                 // the revspec behind a relative base
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
// from those same hunks, so every surface answers to the review base —
// except on an untracked file, which publishes hunks but no marks at
// all, since every one of its lines is trivially added. Git subprocess
// state — staged check, HEAD commit, recent commits — is cached and
// refreshed only on scm events, document switches and saves, never on
// the buffer debounce (buffer edits cannot change the index).
@interface BufferDiffService : NSObject
@property (nonatomic) OakDocument* document;

// The window's review base, as the reader chose it. Setting it triggers
// a recompute.
//
// A relative spec is resolved here, on the same cadence as the other git
// queries — never on the buffer debounce — and only the sha it resolves
// to travels onward. Keying the blob cache by a spec whose meaning moves
// would serve the previous commit's blob after the next commit.
//
// `repoRoot` binds a pinned sha to the repository it was chosen in,
// since it means nothing outside it; the other kinds resolve wherever
// the document happens to be, and pass nil.
- (void)setBaseKind:(OakReviewBaseKind)aKind spec:(NSString*)aSpec repoRoot:(NSString*)aRepoRoot;

// Called on the main queue with each fresh snapshot (stale results are
// dropped, never delivered out of order).
@property (nonatomic, copy) void (^snapshotHandler)(BufferDiffSnapshot* snapshot);

// Called on the main queue when the repo's HEAD is observed to move
// while attached, with what the move was: a commit on this branch, a
// switch to another one, or a rewrite of this one. The commit alone
// cannot tell these apart — two branches can share a commit, and a
// branch can be switched to a descendant of where you were — so the
// branch is compared as well.
@property (nonatomic, copy) void (^headMovedHandler)(NSString* oldHead, NSString* newHead, scm::git_query::head_change change);

- (void)scheduleUpdate; // debounced buffer-edit path
- (void)updateNow;      // immediate recompute, refreshing cached git state
@end
