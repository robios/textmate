#include "locations.h"
#include <io/path.h>
#include <OakSystem/application.h>
#include <oak/duration.h>
#include <oak/debug.h>

namespace bundles
{
	// Order decides who wins a UUID collision: bundles::load skips an item whose
	// UUID a previous location already provided. ‘Subscribed’ therefore comes
	// after ‘Managed’ — an officially signed bundle always beats a colliding
	// subscription, and displacing one is an explicit, journalled act rather
	// than a side effect of this list.
	//
	// The app’s own SharedSupport used to come last, which meant a bundle we
	// ship could never be seen while a copy of the same UUID sat in Managed —
	// and the index reinstalls those. It now sits directly behind the user’s
	// own Bundles/: what we curate into the app wins over anything an index or
	// a subscription distributes, while the user’s local edits still win over
	// us. This applies to every app-shipped bundle, not just Bundle Support,
	// so anything added to SharedSupport inherits that precedence.
	static std::vector<std::string>& locations_vector ()
	{
		static std::string const BundleLocations[] =
		{
			oak::application_t::support(),
			oak::application_t::path("Contents/SharedSupport"),
			oak::application_t::support("Pristine Copy"),
			oak::application_t::support("Managed"),
			oak::application_t::support("Subscribed"),
			path::join("/", "Library/Application Support/TextMate"),
			path::join("/", "Library/Application Support/TextMate/Pristine Copy"),
		};
		static std::vector<std::string> res(std::begin(BundleLocations), std::end(BundleLocations));
		return res;
	}

	std::vector<std::string> const& locations ()
	{
		return locations_vector();
	}

	void set_locations (std::vector<std::string> const& newLocations)
	{
		locations_vector() = newLocations;
	}

} /* bundles */
