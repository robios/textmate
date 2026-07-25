#import "ClaudeIDEContextLockFile.h"
#import <Security/SecRandom.h>
#import <nlohmann/json.hpp>
#import <sys/stat.h>
#import <errno.h>
#import <signal.h>
#import <unistd.h>

using json = nlohmann::json;

@implementation ClaudeIDEContextLockFile
{
	NSString* _directory;
}

+ (NSString*)defaultLockDirectory
{
	char const* configDir = getenv("CLAUDE_CONFIG_DIR");
	NSString* base = configDir && *configDir ? [NSString stringWithUTF8String:configDir] : [NSHomeDirectory() stringByAppendingPathComponent:@".claude"];
	return [base stringByAppendingPathComponent:@"ide"];
}

+ (NSString*)generateAuthToken
{
	uint8_t bytes[16];
	if(SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess)
		arc4random_buf(bytes, sizeof(bytes));

	NSMutableString* token = [NSMutableString stringWithCapacity:2*sizeof(bytes)];
	for(size_t i = 0; i < sizeof(bytes); ++i)
		[token appendFormat:@"%02x", bytes[i]];
	return token;
}

+ (void)removeStaleLockFilesInDirectory:(NSString*)directory
{
	NSArray<NSString*>* entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
	for(NSString* entry in entries)
	{
		if(![entry.pathExtension isEqualToString:@"lock"])
			continue;

		NSString* path = [directory stringByAppendingPathComponent:entry];
		NSData* data = [NSData dataWithContentsOfFile:path];
		if(!data)
			continue;

		json parsed = json::parse((char const*)data.bytes, (char const*)data.bytes + data.length, nullptr, false);
		if(parsed.is_discarded() || !parsed.contains("pid") || !parsed["pid"].is_number_integer())
			continue;

		pid_t pid = parsed["pid"].get<pid_t>();
		if(pid > 0 && kill(pid, 0) == -1 && errno == ESRCH)
		{
			if(unlink(path.fileSystemRepresentation) == 0)
				NSLog(@"[AgentBridge] removed stale lock file %@ (pid %d is gone)", entry, pid);
		}
	}
}

- (instancetype)initWithPort:(NSUInteger)port authToken:(NSString*)authToken directory:(NSString*)directory
{
	if(self = [super init])
	{
		_port      = port;
		_authToken = [authToken copy];
		_directory = [directory copy];
		_path      = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.lock", port]];
	}
	return self;
}

- (BOOL)writeWithWorkspaceFolders:(NSArray<NSString*>*)workspaceFolders
{
	NSError* error;
	if(![NSFileManager.defaultManager createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions: @(S_IRWXU) } error:&error])
	{
		NSLog(@"[AgentBridge] failed to create lock directory %@: %@", _directory, error.localizedDescription);
		return NO;
	}

	json folders = json::array();
	for(NSString* folder in workspaceFolders)
		folders.push_back(folder.UTF8String);

	json lock = {
		{ "pid",              getpid()               },
		{ "workspaceFolders", folders                },
		{ "ideName",          "TextMate"             },
		{ "transport",        "ws"                   },
		{ "authToken",        _authToken.UTF8String  },
	};
	std::string payload = lock.dump(2);

	// Atomic replace: write a 0600 temporary in the same directory, then rename.
	NSString* tmpPath = [_path stringByAppendingFormat:@".%d.tmp", getpid()];
	int fd = open(tmpPath.fileSystemRepresentation, O_WRONLY|O_CREAT|O_TRUNC, 0600);
	if(fd == -1)
	{
		NSLog(@"[AgentBridge] failed to create %@: %s", tmpPath, strerror(errno));
		return NO;
	}

	bool ok = write(fd, payload.data(), payload.size()) == (ssize_t)payload.size();
	close(fd);
	if(ok)
		ok = rename(tmpPath.fileSystemRepresentation, _path.fileSystemRepresentation) == 0;
	if(!ok)
	{
		NSLog(@"[AgentBridge] failed to write lock file %@: %s", _path, strerror(errno));
		unlink(tmpPath.fileSystemRepresentation);
	}
	return ok;
}

- (void)remove
{
	unlink(_path.fileSystemRepresentation);
}
@end
