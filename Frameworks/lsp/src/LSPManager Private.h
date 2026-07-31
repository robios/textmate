#ifndef LSP_MANAGER_PRIVATE_H_D4A21F60
#define LSP_MANAGER_PRIVATE_H_D4A21F60

#import "LSPManager.h"

// The one operation that puts a URI's diagnostics into a loaded document, and
// therefore the only place a test can ask what a publish does to that document.
// Every arrival, re-apply and purge goes through it; asserting against
// -[OakDocument setDiagnostics:] instead would assert about a layer below the
// one that decides which surfaces a publish reaches.
@interface LSPManager (Private)
- (void)applyDiagnostics:(NSArray<NSDictionary*>*)diagnostics toDocument:(OakDocument*)doc;
@end

#endif /* LSP_MANAGER_PRIVATE_H_D4A21F60 */
