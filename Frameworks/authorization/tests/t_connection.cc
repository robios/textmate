#include <authorization/connection.h>

void test_connection ()
{
	int sockets[2];
	socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets[0]);

	// Both ends run on this thread — no fork(), since forking while sibling
	// tests run on other threads can livelock the ASan runtime under
	// gen_test’s parallel runner. Driving both ends sequentially is only safe
	// because each direction’s payload (a few dozen bytes) is far smaller than
	// the socket buffer, so a write never blocks waiting for a reader. Growing
	// the payloads means reintroducing a second thread to drain the peer.
	connection_t server(sockets[1]);
	server << "welcome!" << 42;

	connection_t client(sockets[0]);
	std::string greeting;
	int version;
	client >> greeting >> version;
	OAK_ASSERT_EQ(greeting, "welcome!");
	OAK_ASSERT_EQ(version, 42);
	client << "I am bored" << "quit";

	std::string msg, cmd;
	server >> msg >> cmd;
	OAK_ASSERT_EQ(msg, "I am bored");
	OAK_ASSERT_EQ(cmd, "quit");
}
