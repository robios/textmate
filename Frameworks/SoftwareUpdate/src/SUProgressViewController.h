#ifndef SU_PROGRESS_VIEW_CONTROLLER_H_V5HB9TGM
#define SU_PROGRESS_VIEW_CONTROLLER_H_V5HB9TGM

#import <Cocoa/Cocoa.h>

// A message, a progress bar, and a status line; while progress is set the
// three follow it (description, fraction, bytes and time remaining).
@interface SUProgressViewController : NSViewController
@property (nonatomic) NSTextField*         messageTextField;
@property (nonatomic) NSTextField*         informativeTextField;
@property (nonatomic) NSProgressIndicator* progressIndicator;
@property (nonatomic) NSProgress*          progress;
@end

#endif /* end of include guard: SU_PROGRESS_VIEW_CONTROLLER_H_V5HB9TGM */
