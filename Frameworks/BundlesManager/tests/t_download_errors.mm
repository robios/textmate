#import <BundlesManager/OakDownloadManager.h>
#include <sys/socket.h>
#include <netinet/in.h>

// A download that fails before its first byte — refused connection, redirect
// loop, timeout — never gets as far as launching tar. The transport error is
// the one to report; it used to be replaced by “Unable to launch tar.”

static NSURL* unreachable_loopback_url ()
{
	// Bind an ephemeral port and release it: nothing listens there afterwards
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	OAK_ASSERT_NE(fd, -1);

	sockaddr_in addr = { };
	addr.sin_len         = sizeof(addr);
	addr.sin_family      = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	OAK_ASSERT_EQ(bind(fd, (sockaddr*)&addr, sizeof(addr)), 0);

	socklen_t len = sizeof(addr);
	OAK_ASSERT_EQ(getsockname(fd, (sockaddr*)&addr, &len), 0);
	close(fd);

	return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/TextMate.tar.gz", ntohs(addr.sin_port)]];
}

void test_transport_failure_is_reported_as_such ()
{
	__block NSURL* extracted;
	__block NSError* error;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);

	// Completion arrives on the main queue, which the runner keeps spinning
	id <NSProgressReporting> task = [OakDownloadManager.sharedInstance downloadArchiveAtURL:unreachable_loopback_url() forReplacingURL:nil publicKeys:nil userAgent:@"t_download_errors" transportPolicy:^BOOL(NSURL* url){ return YES; } completionHandler:^(NSURL* extractedArchiveURL, NSError* downloadError){
		extracted = extractedArchiveURL;
		error     = downloadError;
		dispatch_semaphore_signal(done);
	}];
	OAK_ASSERT(task != nil);
	OAK_ASSERT_EQ(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)), 0L);

	OAK_ASSERT(extracted == nil);
	OAK_ASSERT(error != nil);
	OAK_ASSERT([error.domain isEqualToString:NSURLErrorDomain]);
	OAK_ASSERT(![error.localizedDescription containsString:@"tar"]);
}
