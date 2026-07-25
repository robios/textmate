#ifndef MATE_CLIENT_H_XW83LQ4T
#define MATE_CLIENT_H_XW83LQ4T

#include "agent_cli.h"

#include <map>
#include <string>

// One round trip over the mate socket — the UNIX domain socket the ‘mate’ CLI
// also uses, served by RMateServer on the app’s main queue. Deliberately
// connect-only: it never launches TextMate, because every request tm_agent
// makes is about a live editor session.
namespace mate_client
{
	std::string socket_path ();

	// Sends one framed request and reads the reply until the app closes the
	// connection. Returns false when TextMate could not be reached or the
	// exchange failed, with *error explaining which. A rejected request is
	// still a successful round trip: that shows up as ‘status: error’ in
	// *response.
	bool send (agent_cli::request_t const& request, std::map<std::string, std::string>* response, std::string* error);

} /* mate_client */

#endif /* MATE_CLIENT_H_XW83LQ4T */
