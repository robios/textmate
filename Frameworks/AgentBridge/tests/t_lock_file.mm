#import <AgentBridge/AgentBridgeLockFile.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString* temporary_directory ()
{
	return [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"agent-bridge-test-%d-%08x", getpid(), arc4random()]];
}

void test_auth_token_format ()
{
	NSString* first  = [AgentBridgeLockFile generateAuthToken];
	NSString* second = [AgentBridgeLockFile generateAuthToken];

	OAK_ASSERT_EQ(first.length, 32);
	OAK_ASSERT(![first isEqualToString:second]);

	NSCharacterSet* nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
	OAK_ASSERT_EQ([first rangeOfCharacterFromSet:nonHex].location, NSNotFound);
}

void test_lock_file_roundtrip_and_permissions ()
{
	NSString* dir = temporary_directory();
	NSString* token = [AgentBridgeLockFile generateAuthToken];

	AgentBridgeLockFile* lock = [[AgentBridgeLockFile alloc] initWithPort:12345 authToken:token directory:dir];
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

	// A lock owned by a dead process: fork a child that exits immediately.
	pid_t deadPid = fork();
	if(deadPid == 0)
		_exit(0);
	int status;
	waitpid(deadPid, &status, 0);

	AgentBridgeLockFile* staleLock = [[AgentBridgeLockFile alloc] initWithPort:11111 authToken:[AgentBridgeLockFile generateAuthToken] directory:dir];
	OAK_ASSERT([staleLock writeWithWorkspaceFolders:@[ ]]);
	NSString* staleContents = [NSString stringWithContentsOfFile:staleLock.path encoding:NSUTF8StringEncoding error:nil];
	staleContents = [staleContents stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%d", getpid()] withString:[NSString stringWithFormat:@"%d", deadPid]];
	OAK_ASSERT([staleContents writeToFile:staleLock.path atomically:YES encoding:NSUTF8StringEncoding error:nil]);

	// A live lock (our own pid) and a foreign non-JSON file must both survive.
	AgentBridgeLockFile* liveLock = [[AgentBridgeLockFile alloc] initWithPort:22222 authToken:[AgentBridgeLockFile generateAuthToken] directory:dir];
	OAK_ASSERT([liveLock writeWithWorkspaceFolders:@[ ]]);
	NSString* foreignPath = [dir stringByAppendingPathComponent:@"33333.lock"];
	OAK_ASSERT([@"not json" writeToFile:foreignPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);

	[AgentBridgeLockFile removeStaleLockFilesInDirectory:dir];

	OAK_ASSERT(![NSFileManager.defaultManager fileExistsAtPath:staleLock.path]);
	OAK_ASSERT([NSFileManager.defaultManager fileExistsAtPath:liveLock.path]);
	OAK_ASSERT([NSFileManager.defaultManager fileExistsAtPath:foreignPath]);

	[NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}
