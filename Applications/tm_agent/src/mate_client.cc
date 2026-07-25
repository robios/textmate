#include "mate_client.h"

#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace mate_client
{
	std::string socket_path ()
	{
		static std::string const res = "/tmp/textmate-" + std::to_string(getuid()) + ".sock";
		return res;
	}

	bool send (agent_cli::request_t const& request, std::map<std::string, std::string>* response, std::string* error)
	{
		auto fail = [&error](std::string const& message){
			if(error)
				*error = message;
			return false;
		};

		int fd = socket(AF_UNIX, SOCK_STREAM, 0);
		struct sockaddr_un addr = { 0, AF_UNIX };
		std::string const path = socket_path();
		if(path.size() >= sizeof(addr.sun_path))
		{
			if(fd != -1)
				close(fd);
			return fail("socket path is too long: " + path);
		}
		strcpy(addr.sun_path, path.c_str());
		addr.sun_len = SUN_LEN(&addr);

		if(fd == -1 || connect(fd, (sockaddr*)&addr, sizeof(addr)) == -1)
		{
			if(fd != -1)
				close(fd);
			return fail("TextMate does not appear to be running (no socket at " + path + ")");
		}

		// Read the server’s welcome line before sending our request.
		char buf[1024];
		std::string received;
		while(received.find('\n') == std::string::npos)
		{
			ssize_t len = read(fd, buf, sizeof(buf));
			if(len <= 0)
			{
				close(fd);
				return fail("no greeting from TextMate");
			}
			received.insert(received.end(), buf, buf + len);
		}
		received.erase(0, received.find('\n') + 1);

		std::string const frame = agent_cli::frame_request(request);
		if(write(fd, frame.data(), frame.size()) != (ssize_t)frame.size())
		{
			close(fd);
			return fail("failed to send the request to TextMate");
		}

		// The app closes the connection once it has written its reply — which
		// it may do long after the request for tools that resolve
		// asynchronously, so this read is the wait.
		while(ssize_t len = read(fd, buf, sizeof(buf)))
		{
			if(len == -1)
			{
				close(fd);
				return fail("failed to read TextMate’s response");
			}
			received.insert(received.end(), buf, buf + len);
		}
		close(fd);

		if(response)
			*response = agent_cli::parse_response(received);
		return true;
	}

} /* mate_client */
