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
	static std::vector<std::string>& locations_vector ()
	{
		static std::string const BundleLocations[] =
		{
			oak::application_t::support(),
			oak::application_t::support("Pristine Copy"),
			oak::application_t::support("Managed"),
			oak::application_t::support("Subscribed"),
			path::join("/", "Library/Application Support/TextMate"),
			path::join("/", "Library/Application Support/TextMate/Pristine Copy"),
			oak::application_t::path("Contents/SharedSupport"),
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
