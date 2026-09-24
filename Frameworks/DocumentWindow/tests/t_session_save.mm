#import <DocumentWindow/DocumentWindowController.h>
#import <document/OakDocument.h>
#import <OakSystem/application.h>
#import <io/path.h>
#import <ns/ns.h>
#include <filesystem>
#include <mutex>
#include <sys/stat.h>

// The checked session save is exercised against real window controllers, the
// way the application enumerates them (ordered windows whose delegate is a
// registered controller). Everything it writes — the session file and the
// document backups — lives under oak::application_t::support("Session"), so the
// support directory is pointed at a per-run temporary directory, once and
// process-wide, before anything can read it: the session file path is cached
// on first use, and test functions run in parallel, so switching it per test
// would race. Nothing here touches ~/Library/Application Support.

static std::string const kSupportDirectory = []{
	std::string const dir = path::join(to_s(NSTemporaryDirectory()), "t_session_save.XXXXXX");
	std::vector<char> buf(dir.begin(), dir.end());
	buf.push_back('\0');
	std::string const res = mkdtemp(buf.data()) ? std::string(buf.data()) : NULL_STR;
	oak::application_t::set_support(res);
	return res;
}();

struct support_directory_cleanup_t
{
	~support_directory_cleanup_t ()
	{
		if(kSupportDirectory == NULL_STR)
			return;
		std::error_code ec;
		for(auto const& entry : std::filesystem::recursive_directory_iterator(kSupportDirectory, ec))
		{
			if(entry.is_directory(ec))
				chmod(entry.path().c_str(), S_IRWXU);
		}
		std::filesystem::remove_all(kSupportDirectory, ec);
	}
};
static support_directory_cleanup_t support_directory_cleanup;

static std::string session_directory () { return path::join(kSupportDirectory, "Session"); }
static std::string session_plist ()     { return path::join(session_directory(), "Info.plist"); }

// All cases share one session file and the process-wide set of window
// controllers (a save enumerates every window), so they cannot run
// concurrently: each holds this mutex for its whole duration. Inside, the
// controller’s lifetime and the save run in a single main-queue block, so the
// controller’s own deferred session-save timer cannot fire in between either.
static std::mutex& session_mutex ()
{
	static std::mutex mutex;
	return mutex;
}

static void on_main (void(^block)(void))
{
	if(NSThread.isMainThread)
			block();
	else	dispatch_sync(dispatch_get_main_queue(), block);
}

// Loading completes on the main queue, which the runner keeps spinning while
// test functions run on a global queue.
static OakDocument* loaded_document (NSString* content, NSString* customName)
{
	__block OakDocument* doc;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_main_queue(), ^{
		doc = [OakDocument documentWithString:content fileType:@"text.plain" customName:customName];
		[doc loadModalForWindow:nil completionHandler:^(OakDocumentIOResult result, NSString* errorMessage, oak::uuid_t const& filterUUID){
			dispatch_semaphore_signal(done);
		}];
	});
	OAK_ASSERT_EQ(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0L);
	OAK_ASSERT(doc.isLoaded);
	return doc;
}

// An edit as the editor makes one: it moves the document past its last backup.
static void edit_document (OakDocument* doc, NSString* content)
{
	on_main(^{
		[doc beginUndoGrouping];
		doc.content = content;
		[doc endUndoGrouping];
	});
	OAK_ASSERT(doc.isDocumentEdited);
}

// Must be called on the main thread; the controller is closed again by
// close_controller() before the enclosing main-queue block ends.
static DocumentWindowController* controller_with_document (OakDocument* doc)
{
	[NSApplication sharedApplication];
	DocumentWindowController* controller = [[DocumentWindowController alloc] init];
	[controller setValue:@[ doc ] forKey:@"documents"]; // read-only in the public interface
	controller.window.alphaValue = 0;
	[controller.window orderFront:nil];
	return controller;
}

static void close_controller (DocumentWindowController* controller)
{
	[controller close];
}

static NSUInteger saved_document_count ()
{
	NSDictionary* session = [NSDictionary dictionaryWithContentsOfFile:to_ns(session_plist())];
	NSUInteger res = 0;
	for(NSDictionary* project in session[@"projects"])
		res += [project[@"documents"] count];
	return res;
}

void test_failed_backup_is_reported_and_session_file_still_written ()
{
	std::lock_guard<std::mutex> lock(session_mutex());

	std::string const readOnlyDir = path::join(kSupportDirectory, "read-only");
	OAK_ASSERT(path::make_dir(readOnlyDir));
	OAK_ASSERT_EQ(chmod(readOnlyDir.c_str(), S_IRUSR|S_IXUSR|S_IRGRP|S_IXGRP|S_IROTH|S_IXOTH), 0);

	OakDocument* doc = loaded_document(@"unsaved text", @"Backup Fails");
	doc.backupPath = to_ns(path::join(readOnlyDir, "backup")); // saveBackup: reuses a preset path
	edit_document(doc, @"edited text"); // …which would otherwise count as current

	__block BOOL res;
	__block NSError* error;
	__block NSUInteger documentCount;
	on_main(^{
		unlink(session_plist().c_str());
		DocumentWindowController* controller = controller_with_document(doc);
		res = [DocumentWindowController saveSessionIncludingUntitledDocuments:YES error:&error];
		documentCount = saved_document_count();
		close_controller(controller);
	});

	chmod(readOnlyDir.c_str(), S_IRWXU);

	OAK_ASSERT(!res);
	OAK_ASSERT(error != nil);
	OAK_ASSERT([error.localizedDescription containsString:@"Backup Fails"]);
	OAK_ASSERT(path::exists(session_plist()));
	OAK_ASSERT_EQ(documentCount, 1UL);
	OAK_ASSERT(!path::exists(path::join(readOnlyDir, "backup")));
}

// A document loaded with content starts out with backupRevision == revision,
// so a backup path recorded before the first successful write would make the
// next call answer YES with no file on disk. The session directory is made
// read-only for the first save, as a full or unwritable disk would.
void test_failed_first_backup_is_retried ()
{
	std::lock_guard<std::mutex> lock(session_mutex());

	OakDocument* doc = loaded_document(@"unsaved text", @"Retried");

	__block BOOL firstRes, secondRes;
	__block NSError* firstError;
	__block NSError* secondError;
	on_main(^{
		unlink(session_plist().c_str());
		OAK_ASSERT(path::make_dir(session_directory()));
		OAK_ASSERT_EQ(chmod(session_directory().c_str(), S_IRUSR|S_IXUSR|S_IRGRP|S_IXGRP|S_IROTH|S_IXOTH), 0);

		DocumentWindowController* controller = controller_with_document(doc);
		firstRes = [DocumentWindowController saveSessionIncludingUntitledDocuments:YES error:&firstError];
		OAK_ASSERT_EQ(chmod(session_directory().c_str(), S_IRWXU), 0);
		secondRes = [DocumentWindowController saveSessionIncludingUntitledDocuments:YES error:&secondError];
		close_controller(controller);
	});

	OAK_ASSERT(!firstRes);
	OAK_ASSERT(firstError != nil);
	OAK_ASSERT([firstError.localizedDescription containsString:@"Retried"]);

	OAK_ASSERT(secondRes);
	OAK_ASSERT(secondError == nil);
	OAK_ASSERT(doc.backupPath != nil);
	OAK_ASSERT(path::exists(to_s(doc.backupPath)));
	OAK_ASSERT_EQ(path::get_attr(to_s(doc.backupPath), "com.macromates.backup.identifier"), to_s(doc.identifier.UUIDString));
	OAK_ASSERT(path::exists(session_plist()));
}

void test_failed_session_file_is_reported_and_backups_still_written ()
{
	std::lock_guard<std::mutex> lock(session_mutex());

	OakDocument* doc = loaded_document(@"unsaved text", @"Plist Fails");

	__block BOOL res;
	__block NSError* error;
	on_main(^{
		unlink(session_plist().c_str());
		OAK_ASSERT(path::make_dir(session_plist())); // the atomic write cannot rename onto a directory
		DocumentWindowController* controller = controller_with_document(doc);
		res = [DocumentWindowController saveSessionIncludingUntitledDocuments:YES error:&error];
		close_controller(controller);
		rmdir(session_plist().c_str());
	});

	OAK_ASSERT(!res);
	OAK_ASSERT(error != nil);
	OAK_ASSERT([error.localizedDescription containsString:to_ns(session_plist())]);

	OAK_ASSERT(doc.backupPath != nil);
	OAK_ASSERT_EQ(path::parent(to_s(doc.backupPath)), session_directory());
	OAK_ASSERT(path::exists(to_s(doc.backupPath)));
	OAK_ASSERT_EQ(path::get_attr(to_s(doc.backupPath), "com.macromates.backup.identifier"), to_s(doc.identifier.UUIDString));

	__block BOOL isCurrent;
	on_main(^{ isCurrent = [doc saveBackup:nil]; });
	OAK_ASSERT(isCurrent);
}

void test_successful_save_and_backup_lookup ()
{
	std::lock_guard<std::mutex> lock(session_mutex());

	OakDocument* doc   = loaded_document(@"unsaved text", @"Both Succeed");
	OakDocument* empty = loaded_document(@"", @"Nothing To Back Up");

	__block BOOL res, disabledRes, emptyRes;
	__block NSError* error;
	__block NSError* disabledError;
	on_main(^{
		unlink(session_plist().c_str());
		DocumentWindowController* controller = controller_with_document(doc);
		res = [DocumentWindowController saveSessionIncludingUntitledDocuments:YES error:&error];

		[DocumentWindowController disableSessionSave];
		disabledRes = [DocumentWindowController saveSessionIncludingUntitledDocuments:YES error:&disabledError];
		[DocumentWindowController enableSessionSave];

		close_controller(controller);

		emptyRes = [empty saveBackup:nil];
	});

	OAK_ASSERT(res);
	OAK_ASSERT(error == nil);
	OAK_ASSERT(path::exists(session_plist()));

	OAK_ASSERT(!disabledRes);
	OAK_ASSERT(disabledError != nil);

	// Nothing needs backing up: an unmodified, empty untitled document
	OAK_ASSERT(emptyRes);
	OAK_ASSERT(empty.backupPath == nil);

	// The live document would be found through the document controller, so look
	// up a copy of its backup under an identifier no open document has; only
	// the session directory can answer that.
	OAK_ASSERT(doc.backupPath != nil);
	std::string const copy = path::join(session_directory(), "Lookup Copy");
	OAK_ASSERT_EQ(copyfile(to_s(doc.backupPath).c_str(), copy.c_str(), nullptr, COPYFILE_ALL), 0);
	NSUUID* identifier = [NSUUID UUID];
	OAK_ASSERT(path::set_attributes(copy, { { "com.macromates.backup.identifier", to_s(identifier.UUIDString) } }));

	__block OakDocument* found;
	on_main(^{ found = [OakDocument documentWithIdentifier:identifier]; });
	OAK_ASSERT(found != nil);
	OAK_ASSERT(found != doc);
	OAK_ASSERT_EQ(to_s(found.backupPath), copy);
}
