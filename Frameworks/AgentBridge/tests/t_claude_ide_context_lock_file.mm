#import <AgentBridge/ClaudeIDEContextLockFile.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString* temporary_directory ()
{
	return [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"agent-bridge-test-%d-%08x", getpid(), arc4random()]];
}

void test_auth_token_format ()
{
	NSString* first  = [ClaudeIDEContextLockFile generateAuthToken];
	NSString* second = [ClaudeIDEContextLockFile generateAuthToken];

	OAK_ASSERT_EQ(first.length, 32);
	OAK_ASSERT(![first isEqualToString:second]);

	NSCharacterSet* nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
	OAK_ASSERT_EQ([first rangeOfCharacterFromSet:nonHex].location, NSNotFound);
}

void test_lock_file_roundtrip_and_permissions ()
{
	NSString* dir = temporary_directory();
	NSString* token = [ClaudeIDEContextLockFile generateAuthToken];

	ClaudeIDEContextLockFile* lock = [[ClaudeIDEContextLockFile alloc] initWithPort:12345 authToken:token directory:dir];
	OAK_ASSERT([lock writeWithWorkspaceFolders:@[ @"/tmp/project" ]]);
	OAK_ASSERT([lock.path.lastPathComponent isEqualToString:@"12345.lock"]);

	struct stat dirInfo, fileInfo;
	OAK_ASSERT_EQ(stat(dir.fileSystemRepresentation, &dirInfo), 0);
	OAK_ASSERT_EQ(dirInfo.st_mode & 0777, 0700);
	OAK_ASSERT_EQ(stat(lock.path.fileSystemRepresentation, &fileInfo), 0);
	OAK_ASSERT_EQ(fileInfo.st_mode & 0777, 0600);

	NSData* data = [NSData dataWithContentsOfFile:lock.path];
	NSDictionary* parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	OAK_ASSERT(parsed);
	OAK_ASSERT_EQ([parsed[@"pid"] intValue], getpid());
	OAK_ASSERT([parsed[@"ideName"] isEqualToString:@"TextMate"]);
	OAK_ASSERT([parsed[@"transport"] isEqualToString:@"ws"]);
	OAK_ASSERT([parsed[@"authToken"] isEqualToString:token]);
	OAK_ASSERT([parsed[@"workspaceFolders"] isEqualToArray:@[ @"/tmp/project" ]]);

	[lock remove];
	OAK_ASSERT(![NSFileManager.defaultManager fileExistsAtPath:lock.path]);

	[NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

void test_stale_lock_cleanup ()
{
	NSString* dir = temporary_directory();

	// A lock owned by a dead process: spawn a short-lived child and reap it.
	// posix_spawn, not fork() — forking while sibling tests run on other
	// threads can livelock the ASan runtime under gen_test’s parallel runner.
	pid_t deadPid = -1;
	char const* argv[] = { "/usr/bin/true", NULL };
	OAK_ASSERT_EQ(posix_spawn(&deadPid, argv[0], NULL, NULL, (char* const*)argv, NULL), 0);
	int status;
	OAK_ASSERT_EQ(waitpid(deadPid, &status, 0), deadPid);

	ClaudeIDEContextLockFile* staleLock = [[ClaudeIDEContextLockFile alloc] initWithPort:11111 authToken:[ClaudeIDEContextLockFile generateAuthToken] directory:dir];
	OAK_ASSERT([staleLock writeWithWorkspaceFolders:@[ ]]);
	// Rewrite the pid through JSON rather than textual substitution: the
	// authToken is 32 hex characters, so it can contain our pid’s decimal
	// digits as a substring, and a blind search-and-replace would corrupt it.
	NSMutableDictionary* staleContents = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:staleLock.path] options:NSJSONReadingMutableContainers error:nil];
	OAK_ASSERT(staleContents);
	staleContents[@"pid"] = @(deadPid);
	OAK_ASSERT([[NSJSONSerialization dataWithJSONObject:staleContents options:0 error:nil] writeToFile:staleLock.path atomically:YES]);

	// A live lock (our own pid) and a foreign non-JSON file must both survive.
	ClaudeIDEContextLockFile* liveLock = [[ClaudeIDEContextLockFile alloc] initWithPort:22222 authToken:[ClaudeIDEContextLockFile generateAuthToken] directory:dir];
	OAK_ASSERT([liveLock writeWithWorkspaceFolders:@[ ]]);
	NSString* foreignPath = [dir stringByAppendingPathComponent:@"33333.lock"];
	OAK_ASSERT([@"not json" writeToFile:foreignPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);

	[ClaudeIDEContextLockFile removeStaleLockFilesInDirectory:dir];

	OAK_ASSERT(![NSFileManager.defaultManager fileExistsAtPath:staleLock.path]);
	OAK_ASSERT([NSFileManager.defaultManager fileExistsAtPath:liveLock.path]);
	OAK_ASSERT([NSFileManager.defaultManager fileExistsAtPath:foreignPath]);

	[NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}
