#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// UDP port the network pointer receiver listens on. Also advertised over Bonjour.
extern const uint16_t BrowserMotionPointerUDPPort;
/// Bonjour service type advertised by the receiver.
extern NSString * const BrowserMotionPointerBonjourType;

@protocol BrowserMotionInputControllerDelegate <NSObject>

- (void)motionInputControllerMoveCursorByDelta:(CGPoint)delta;
- (void)motionInputControllerScrollByDelta:(CGPoint)delta;
- (void)motionInputControllerPerformPrimaryAction;
- (void)motionInputControllerPerformBackAction;

@end

/// Two jobs:
/// 1. Probe: watches every GCController tvOS reports (Siri Remote, iPhone Control Center
///    remote, game controllers), turns on their motion sensors and shows what data arrives.
/// 2. Receiver: listens for pointer packets from a companion iPhone app (or the test script)
///    over UDP on the local network.
/// A debug overlay shows both in real time.
@interface BrowserMotionInputController : NSObject

+ (instancetype)sharedController;

@property (nonatomic, weak, nullable) id<BrowserMotionInputControllerDelegate> delegate;

/// Shows the on-screen debug overlay. Persisted, default NO.
@property (nonatomic, getter=isDebugOverlayVisible) BOOL debugOverlayVisible;

/// Lets gyroscope data from game controllers / remotes move the cursor. Persisted, default NO.
/// (Network pointer packets always move the cursor.)
@property (nonatomic, getter=isControllerGyroPointerEnabled) BOOL controllerGyroPointerEnabled;

/// Pixels of cursor movement per radian of rotation. Persisted, default 2600.
@property (nonatomic) CGFloat pointerSensitivity;

/// Installs the overlay into rootView and starts probing / listening. Call once.
- (void)startWithRootView:(UIView *)rootView;

/// Plain-text snapshot of everything the overlay shows (also logged to the console).
- (NSString *)diagnosticReport;

@end

NS_ASSUME_NONNULL_END
