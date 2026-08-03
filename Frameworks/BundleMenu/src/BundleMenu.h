#ifndef BUNDLEMENU_H_BI4UDOAR
#define BUNDLEMENU_H_BI4UDOAR

#import <bundles/bundles.h>

@interface BundleMenuDelegate : NSObject <NSMenuDelegate>
@property (class, readonly) BundleMenuDelegate* sharedInstance;
@end

// Populate a menu with bundle items, grouped under bundle-name headings when
// more than one bundle contributed and ordered by each bundle’s own menu where
// it has one. `menuAction` is normally performBundleItemWithUUIDStringFrom:,
// which reads the item’s UUID back off the represented object; `setKeys` shows
// each item’s key equivalent and tab trigger without claiming them for this
// menu. Public because a curated cross-bundle list is not only a proxy item —
// the Terminal menu’s launchers are one too.
void OakAddBundlesToMenu (std::vector<bundles::item_ptr> const& items, bool setKeys, NSMenu* aMenu, SEL menuAction);

bundles::item_ptr OakShowMenuForBundleItems (std::vector<bundles::item_ptr> const& items, NSView* view, NSPoint pos);

#endif /* end of include guard: BUNDLEMENU_H_BI4UDOAR */
