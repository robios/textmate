#import "OakDocumentTestingSPI.h"
#import <io/path.h>
#import <sys/xattr.h>

// A backup must carry its com.macromates.backup.* attributes to be restorable,
// and path::set_attributes() answers true even when fsetxattr() failed. These
// cases stand in for a write that fails half-way (a full disk, say): the file
// exists but a required attribute does not.

static std::string attributed_file (std::map<std::string, std::string> const& attributes)
{
	std::string const path = path::temp("backup_attributes");
	OAK_ASSERT(path::set_content(path, "unsaved text"));
	OAK_ASSERT(path::set_attributes(path, attributes));
	return path;
}

void test_all_backup_attributes_written ()
{
	std::map<std::string, std::string> const attributes = {
		{ "com.macromates.backup.identifier",  "8F5B3B4E-1A2B-4C3D-9E8F-0A1B2C3D4E5F" },
		{ "com.macromates.backup.path",        "/tmp/unsaved.txt" },
		{ "com.macromates.backup.modified",    NULL_STR }, // “remove”, nothing to read back
		{ "com.macromates.selectionRange",     "1" },
	};
	std::string const path = attributed_file(attributes);
	OAK_ASSERT(OakDocumentBackupAttributesWritten(path, attributes));
	unlink(path.c_str());
}

void test_missing_required_attribute_is_detected ()
{
	std::map<std::string, std::string> const attributes = {
		{ "com.macromates.backup.identifier",  "8F5B3B4E-1A2B-4C3D-9E8F-0A1B2C3D4E5F" },
		{ "com.macromates.backup.path",        "/tmp/unsaved.txt" },
	};
	std::string const path = attributed_file(attributes);
	OAK_ASSERT_EQ(removexattr(path.c_str(), "com.macromates.backup.identifier", 0), 0);
	OAK_ASSERT(!OakDocumentBackupAttributesWritten(path, attributes));
	unlink(path.c_str());
}

void test_wrong_required_attribute_value_is_detected ()
{
	std::map<std::string, std::string> const attributes = {
		{ "com.macromates.backup.identifier",  "8F5B3B4E-1A2B-4C3D-9E8F-0A1B2C3D4E5F" },
	};
	std::string const path = attributed_file(attributes);
	OAK_ASSERT(path::set_attributes(path, { { "com.macromates.backup.identifier", "stale" } }));
	OAK_ASSERT(!OakDocumentBackupAttributesWritten(path, attributes));
	unlink(path.c_str());
}

void test_other_attributes_are_not_required ()
{
	std::map<std::string, std::string> const attributes = {
		{ "com.macromates.backup.identifier",  "8F5B3B4E-1A2B-4C3D-9E8F-0A1B2C3D4E5F" },
		{ "com.macromates.selectionRange",     "1" },
	};
	std::string const path = attributed_file(attributes);
	OAK_ASSERT_EQ(removexattr(path.c_str(), "com.macromates.selectionRange", 0), 0);
	OAK_ASSERT(OakDocumentBackupAttributesWritten(path, attributes));
	unlink(path.c_str());
}
