#import <map>
#import <string>

// The check saveBackup: runs before it moves a backup into place: every
// com.macromates.backup.* attribute it asked for must read back from the file,
// because path::set_attributes() swallows a failed fsetxattr(). Declared here
// so a test can drive it against a file of its own making; the generated
// runner wraps each test file in a namespace, so the declaration cannot live
// in the test.
bool OakDocumentBackupAttributesWritten (std::string const& path, std::map<std::string, std::string> const& attributes);
