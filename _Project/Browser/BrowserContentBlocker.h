#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Ad & tracker blocking for the runtime WKWebView, using WebKit content rule lists.
/// The rules are compiled once and applied inside WebKit's networking process,
/// so blocked requests never leave the device.
@interface BrowserContentBlocker : NSObject

+ (instancetype)sharedBlocker;

/// Persisted in NSUserDefaults (key "BrowserAdBlockEnabled"), default YES.
@property (nonatomic, getter=isEnabled) BOOL enabled;

/// YES once the rule list has been compiled successfully.
@property (nonatomic, readonly, getter=isReady) BOOL ready;

/// Registers a WKUserContentController (typed as id because WebKit is loaded at runtime).
/// The rule list is added now if it is ready, or as soon as compilation finishes.
- (void)attachToUserContentController:(id)userContentController;

+ (NSArray<NSString *> *)blockedDomains;

@end

NS_ASSUME_NONNULL_END
