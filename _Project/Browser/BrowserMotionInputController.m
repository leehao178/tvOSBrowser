#import "BrowserMotionInputController.h"

#import <GameController/GameController.h>
#import <Network/Network.h>
#import <QuartzCore/QuartzCore.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

const uint16_t BrowserMotionPointerUDPPort = 47800;
NSString * const BrowserMotionPointerBonjourType = @"_tvbpointer._udp";

static NSString * const kDebugOverlayKey = @"BrowserMotionDebugOverlayVisible";
static NSString * const kGyroPointerKey = @"BrowserMotionControllerGyroPointerEnabled";
static NSString * const kSensitivityKey = @"BrowserMotionPointerSensitivity";

static const double kGyroDeadZone = 0.015;       // rad/s, ignores hand tremor
static const double kGyroSmoothing = 0.35;       // 0 = no smoothing, closer to 1 = smoother/laggier
static const CFTimeInterval kMaxSampleInterval = 0.05;

#pragma mark - Per-source stats

@interface BrowserMotionSourceStats : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic) BOOL hasMotion;
@property (nonatomic) BOOL hasRotationRate;
@property (nonatomic) BOOL hasAttitude;
@property (nonatomic) BOOL needsManualActivation;
@property (nonatomic) BOOL sensorsActive;
@property (nonatomic) NSUInteger sampleCount;
@property (nonatomic) NSUInteger windowCount;
@property (nonatomic) CFTimeInterval windowStart;
@property (nonatomic) double hz;
@property (nonatomic) CFTimeInterval lastSampleTime;
@property (nonatomic) GCRotationRate rotationRate;
@property (nonatomic) GCAcceleration gravity;
@property (nonatomic) GCAcceleration userAcceleration;
@property (nonatomic) CGPoint smoothedDelta;
@end

@implementation BrowserMotionSourceStats

- (void)countSampleAt:(CFTimeInterval)now {
    self.sampleCount += 1;
    self.windowCount += 1;
    if (self.windowStart == 0) {
        self.windowStart = now;
    }
    CFTimeInterval elapsed = now - self.windowStart;
    if (elapsed >= 1.0) {
        self.hz = self.windowCount / elapsed;
        self.windowCount = 0;
        self.windowStart = now;
    }
}

- (double)currentHzAt:(CFTimeInterval)now {
    // Decay to 0 when samples stop arriving.
    return (now - self.lastSampleTime) > 1.5 ? 0 : self.hz;
}

@end

#pragma mark - Controller

@interface BrowserMotionInputController ()

@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, strong) UIView *overlayView;
@property (nonatomic, strong) UILabel *overlayLabel;
@property (nonatomic, strong) NSTimer *overlayTimer;
@property (nonatomic, strong) NSMapTable<GCController *, BrowserMotionSourceStats *> *controllerStats;
@property (nonatomic) BOOL started;

// Network receiver
@property (nonatomic, strong, nullable) nw_listener_t listener;
@property (nonatomic, strong) NSMutableArray *connections;
@property (nonatomic, copy) NSString *listenerState;
@property (nonatomic, strong) BrowserMotionSourceStats *networkStats;
@property (nonatomic, copy) NSString *lastSender;
@property (nonatomic, copy) NSString *lastSenderName;
@property (nonatomic, copy) NSString *lastPacketType;
@property (nonatomic) NSUInteger badPackets;
@property (nonatomic) double lastDYaw;
@property (nonatomic) double lastDPitch;

@end

@implementation BrowserMotionInputController

+ (instancetype)sharedController {
    static BrowserMotionInputController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[BrowserMotionInputController alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kDebugOverlayKey: @NO,
            kGyroPointerKey: @NO,
            kSensitivityKey: @2600.0,
        }];
        _controllerStats = [NSMapTable weakToStrongObjectsMapTable];
        _connections = [NSMutableArray array];
        _listenerState = @"not started";
        _networkStats = [BrowserMotionSourceStats new];
        _networkStats.name = @"Network pointer";
        _lastSender = @"-";
        _lastSenderName = @"-";
        _lastPacketType = @"-";
    }
    return self;
}

#pragma mark - Settings

- (BOOL)isDebugOverlayVisible {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDebugOverlayKey];
}

- (void)setDebugOverlayVisible:(BOOL)visible {
    [[NSUserDefaults standardUserDefaults] setBool:visible forKey:kDebugOverlayKey];
    [self updateOverlayVisibility];
}

- (BOOL)isControllerGyroPointerEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kGyroPointerKey];
}

- (void)setControllerGyroPointerEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kGyroPointerKey];
}

- (CGFloat)pointerSensitivity {
    return (CGFloat)[[NSUserDefaults standardUserDefaults] doubleForKey:kSensitivityKey];
}

- (void)setPointerSensitivity:(CGFloat)sensitivity {
    [[NSUserDefaults standardUserDefaults] setDouble:MIN(MAX(sensitivity, 300.0), 10000.0) forKey:kSensitivityKey];
}

#pragma mark - Start

- (void)startWithRootView:(UIView *)rootView {
    if (self.started) {
        return;
    }
    self.started = YES;
    self.rootView = rootView;

    [self installOverlay];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(controllerDidConnect:) name:GCControllerDidConnectNotification object:nil];
    [center addObserver:self selector:@selector(controllerDidDisconnect:) name:GCControllerDidDisconnectNotification object:nil];
    for (GCController *controller in [GCController controllers]) {
        [self registerController:controller];
    }

    [self startListener];
    NSLog(@"[Motion] started.\n%@", [self diagnosticReport]);
}

#pragma mark - GameController probe

- (void)controllerDidConnect:(NSNotification *)notification {
    GCController *controller = notification.object;
    if ([controller isKindOfClass:[GCController class]]) {
        [self registerController:controller];
    }
}

- (void)controllerDidDisconnect:(NSNotification *)notification {
    GCController *controller = notification.object;
    if ([controller isKindOfClass:[GCController class]]) {
        NSLog(@"[Motion] controller disconnected: %@", controller.vendorName ?: @"(unknown)");
        controller.motion.valueChangedHandler = nil;
        [self.controllerStats removeObjectForKey:controller];
    }
}

- (NSString *)kindForController:(GCController *)controller {
    NSMutableArray *parts = [NSMutableArray array];
    if (controller.productCategory.length > 0) {
        [parts addObject:controller.productCategory];
    }
    if (controller.extendedGamepad != nil) {
        [parts addObject:@"extended"];
    } else if (controller.microGamepad != nil) {
        [parts addObject:@"micro"];
    }
    if (controller.isAttachedToDevice) {
        [parts addObject:@"attached"];
    }
    return parts.count > 0 ? [parts componentsJoinedByString:@", "] : @"unknown";
}

- (void)registerController:(GCController *)controller {
    BrowserMotionSourceStats *stats = [self.controllerStats objectForKey:controller];
    if (stats == nil) {
        stats = [BrowserMotionSourceStats new];
        [self.controllerStats setObject:stats forKey:controller];
    }
    stats.name = controller.vendorName ?: @"(no name)";
    stats.kind = [self kindForController:controller];

    GCMotion *motion = controller.motion;
    stats.hasMotion = (motion != nil);
    if (motion != nil) {
        stats.hasRotationRate = motion.hasRotationRate;
        stats.hasAttitude = motion.hasAttitude;
        stats.needsManualActivation = motion.sensorsRequireManualActivation;
        if (motion.sensorsRequireManualActivation) {
            motion.sensorsActive = YES; // DualShock 4 / DualSense need this
        }
        stats.sensorsActive = motion.sensorsActive;

        __weak typeof(self) weakSelf = self;
        __weak BrowserMotionSourceStats *weakStats = stats;
        motion.valueChangedHandler = ^(GCMotion *updatedMotion) {
            [weakSelf handleMotion:updatedMotion stats:weakStats];
        };
    }

    NSLog(@"[Motion] controller connected: name=%@ kind=%@ motion=%@ rotationRate=%@ attitude=%@ manualActivation=%@ sensorsActive=%@",
          stats.name, stats.kind,
          stats.hasMotion ? @"YES" : @"NO",
          stats.hasRotationRate ? @"YES" : @"NO",
          stats.hasAttitude ? @"YES" : @"NO",
          stats.needsManualActivation ? @"YES" : @"NO",
          stats.sensorsActive ? @"YES" : @"NO");
}

- (void)handleMotion:(GCMotion *)motion stats:(BrowserMotionSourceStats *)stats {
    if (stats == nil) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = stats.lastSampleTime > 0 ? MIN(now - stats.lastSampleTime, kMaxSampleInterval) : 0;
    stats.lastSampleTime = now;
    [stats countSampleAt:now];
    stats.gravity = motion.gravity;
    stats.userAcceleration = motion.userAcceleration;
    stats.sensorsActive = motion.sensorsActive;
    if (!motion.hasRotationRate) {
        return;
    }
    GCRotationRate rate = motion.rotationRate;
    stats.rotationRate = rate;

    if (!self.controllerGyroPointerEnabled || dt <= 0) {
        return;
    }

    // Remote held pointing at the TV: z is the axis out of the remote's face (yaw),
    // x runs across its width (pitch). Turning right = negative z, tipping up = positive x.
    double yawRate = -rate.z;
    double pitchRate = rate.x;
    if (fabs(yawRate) < kGyroDeadZone) yawRate = 0;
    if (fabs(pitchRate) < kGyroDeadZone) pitchRate = 0;

    CGFloat k = self.pointerSensitivity;
    CGPoint raw = CGPointMake(yawRate * dt * k, -pitchRate * dt * k);
    CGPoint smoothed = CGPointMake(stats.smoothedDelta.x * kGyroSmoothing + raw.x * (1.0 - kGyroSmoothing),
                                   stats.smoothedDelta.y * kGyroSmoothing + raw.y * (1.0 - kGyroSmoothing));
    stats.smoothedDelta = smoothed;
    if (smoothed.x == 0 && smoothed.y == 0) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate motionInputControllerMoveCursorByDelta:smoothed];
    });
}

#pragma mark - Network receiver

- (void)startListener {
    nw_parameters_t parameters = nw_parameters_create_secure_udp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                                 NW_PARAMETERS_DEFAULT_CONFIGURATION);
    NSString *port = [NSString stringWithFormat:@"%u", BrowserMotionPointerUDPPort];
    nw_listener_t listener = nw_listener_create_with_port(port.UTF8String, parameters);
    if (listener == nil) {
        self.listenerState = @"failed to create listener";
        NSLog(@"[Motion] %@", self.listenerState);
        return;
    }

    NSString *serviceName = [UIDevice currentDevice].name ?: @"Apple TV";
    nw_advertise_descriptor_t advertise = nw_advertise_descriptor_create_bonjour_service(serviceName.UTF8String,
                                                                                         BrowserMotionPointerBonjourType.UTF8String,
                                                                                         NULL);
    if (advertise != nil) {
        nw_listener_set_advertise_descriptor(listener, advertise);
    }

    nw_listener_set_queue(listener, dispatch_get_main_queue());

    __weak typeof(self) weakSelf = self;
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        switch (state) {
            case nw_listener_state_waiting: strongSelf.listenerState = @"waiting"; break;
            case nw_listener_state_ready: strongSelf.listenerState = @"ready"; break;
            case nw_listener_state_failed: strongSelf.listenerState = @"failed"; break;
            case nw_listener_state_cancelled: strongSelf.listenerState = @"cancelled"; break;
            default: strongSelf.listenerState = @"invalid"; break;
        }
        if (error != nil) {
            strongSelf.listenerState = [strongSelf.listenerState stringByAppendingFormat:@" (error %d)", nw_error_get_error_code(error)];
        }
        NSLog(@"[Motion] UDP listener %@", strongSelf.listenerState);
        if (state == nw_listener_state_failed) {
            nw_listener_cancel(listener);
            strongSelf.listener = nil;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf startListener];
            });
        }
    });

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        [weakSelf acceptConnection:connection];
    });

    self.listener = listener;
    nw_listener_start(listener);
}

- (void)acceptConnection:(nw_connection_t)connection {
    [self.connections addObject:connection];
    nw_connection_set_queue(connection, dispatch_get_main_queue());

    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        (void)error;
        if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            [weakSelf.connections removeObject:connection];
        }
    });
    nw_connection_start(connection);
    [self receiveOnConnection:connection];

    // Keep at most a handful of flows around; the newest sender wins.
    while (self.connections.count > 8) {
        nw_connection_t oldest = self.connections.firstObject;
        [self.connections removeObjectAtIndex:0];
        nw_connection_cancel(oldest);
    }
}

- (void)receiveOnConnection:(nw_connection_t)connection {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive_message(connection, ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t error) {
        (void)context;
        (void)is_complete;
        if (content != nil) {
            [weakSelf handleDatagram:(NSData *)content fromConnection:connection];
        }
        if (error == nil) {
            [weakSelf receiveOnConnection:connection];
        }
    });
}

- (NSString *)addressForConnection:(nw_connection_t)connection {
    nw_endpoint_t endpoint = nw_connection_copy_endpoint(connection);
    if (endpoint == nil || nw_endpoint_get_type(endpoint) != nw_endpoint_type_address) {
        return @"?";
    }
    char *address = nw_endpoint_copy_address_string(endpoint);
    if (address == NULL) {
        return @"?";
    }
    NSString *result = [NSString stringWithUTF8String:address];
    free(address);
    return result ?: @"?";
}

- (void)sendJSON:(NSDictionary *)object onConnection:(nw_connection_t)connection {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (data == nil) {
        return;
    }
    dispatch_data_t payload = dispatch_data_create(data.bytes, data.length, dispatch_get_main_queue(), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(connection, payload, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        (void)error;
    });
}

static double BrowserNumber(NSDictionary *packet, NSString *key) {
    id value = packet[key];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
}

/// Packet format (one JSON object per UDP datagram, protocol v1):
///   {"type":"hello","name":"My iPhone"}             → receiver replies {"type":"welcome",...}
///   {"type":"motion","dyaw":0.01,"dpitch":-0.002}   radians turned since the previous packet;
///                                                    +dyaw = turned right, +dpitch = tipped up
///   {"type":"move","dx":12,"dy":-4}                 cursor delta in screen points
///   {"type":"scroll","dx":0,"dy":120}               scroll delta in points
///   {"type":"click"}                                primary action at the cursor
- (void)handleDatagram:(NSData *)data fromConnection:(nw_connection_t)connection {
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        self.badPackets += 1;
        return;
    }
    NSDictionary *packet = object;
    NSString *type = [packet[@"type"] isKindOfClass:[NSString class]] ? packet[@"type"] : @"";

    CFTimeInterval now = CACurrentMediaTime();
    self.networkStats.lastSampleTime = now;
    [self.networkStats countSampleAt:now];
    self.lastSender = [self addressForConnection:connection];
    self.lastPacketType = type.length > 0 ? type : @"(none)";

    if ([type isEqualToString:@"hello"]) {
        NSString *name = [packet[@"name"] isKindOfClass:[NSString class]] ? packet[@"name"] : @"(unnamed)";
        self.lastSenderName = name;
        NSLog(@"[Motion] hello from %@ (%@)", name, self.lastSender);
        [self sendJSON:@{
            @"type": @"welcome",
            @"v": @1,
            @"device": [UIDevice currentDevice].name ?: @"Apple TV",
            @"sensitivity": @(self.pointerSensitivity),
        } onConnection:connection];
    } else if ([type isEqualToString:@"motion"]) {
        double dyaw = BrowserNumber(packet, @"dyaw");
        double dpitch = BrowserNumber(packet, @"dpitch");
        self.lastDYaw = dyaw;
        self.lastDPitch = dpitch;
        CGFloat k = self.pointerSensitivity;
        CGPoint delta = CGPointMake(dyaw * k, -dpitch * k);
        if (delta.x != 0 || delta.y != 0) {
            [self.delegate motionInputControllerMoveCursorByDelta:delta];
        }
    } else if ([type isEqualToString:@"move"]) {
        CGPoint delta = CGPointMake(BrowserNumber(packet, @"dx"), BrowserNumber(packet, @"dy"));
        [self.delegate motionInputControllerMoveCursorByDelta:delta];
    } else if ([type isEqualToString:@"scroll"]) {
        CGPoint delta = CGPointMake(BrowserNumber(packet, @"dx"), BrowserNumber(packet, @"dy"));
        [self.delegate motionInputControllerScrollByDelta:delta];
    } else if ([type isEqualToString:@"click"]) {
        [self.delegate motionInputControllerPerformPrimaryAction];
    } else {
        self.badPackets += 1;
    }
}

#pragma mark - Diagnostics

- (NSArray<NSString *> *)localIPv4Addresses {
    NSMutableArray *addresses = [NSMutableArray array];
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        return addresses;
    }
    for (struct ifaddrs *cursor = interfaces; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_addr == NULL || cursor->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        if ((cursor->ifa_flags & IFF_UP) == 0 || (cursor->ifa_flags & IFF_LOOPBACK) != 0) {
            continue;
        }
        char buffer[INET_ADDRSTRLEN] = {0};
        const struct sockaddr_in *address = (const struct sockaddr_in *)cursor->ifa_addr;
        if (inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer)) != NULL) {
            [addresses addObject:[NSString stringWithFormat:@"%s (%s)", buffer, cursor->ifa_name]];
        }
    }
    freeifaddrs(interfaces);
    return addresses;
}

static NSString *YesNo(BOOL value) {
    return value ? @"YES" : @"no";
}

- (NSString *)diagnosticReport {
    CFTimeInterval now = CACurrentMediaTime();
    NSMutableString *report = [NSMutableString string];

    static NSUInteger refreshCount = 0;
    refreshCount += 1;
    [report appendFormat:@"refresh #%lu  t=%.1fs\n", (unsigned long)refreshCount, now];

    NSArray<GCController *> *controllers = [GCController controllers];
    [report appendFormat:@"GAME CONTROLLERS (%lu)   gyro pointer: %@   sensitivity: %.0f px/rad\n",
     (unsigned long)controllers.count, self.controllerGyroPointerEnabled ? @"ON" : @"off", self.pointerSensitivity];
    if (controllers.count == 0) {
        [report appendString:@"  (none reported by tvOS)\n"];
    }
    for (GCController *controller in controllers) {
        BrowserMotionSourceStats *stats = [self.controllerStats objectForKey:controller];
        if (stats == nil) {
            [self registerController:controller];
            stats = [self.controllerStats objectForKey:controller];
        }
        [report appendFormat:@"• %@ [%@]\n", stats.name, stats.kind];
        [report appendFormat:@"  motion:%@ gyro:%@ attitude:%@ manual:%@ active:%@\n",
         YesNo(stats.hasMotion), YesNo(stats.hasRotationRate), YesNo(stats.hasAttitude),
         YesNo(stats.needsManualActivation), YesNo(stats.sensorsActive)];
        if (stats.hasMotion) {
            GCRotationRate r = stats.rotationRate;
            GCAcceleration g = stats.gravity;
            GCAcceleration a = stats.userAcceleration;
            NSString *lastSample = stats.lastSampleTime > 0
                ? [NSString stringWithFormat:@"%.1fs ago", now - stats.lastSampleTime]
                : @"never";
            [report appendFormat:@"  samples:%lu  %.0f Hz  last:%@\n", (unsigned long)stats.sampleCount, [stats currentHzAt:now], lastSample];
            [report appendFormat:@"  rot  x%+6.2f y%+6.2f z%+6.2f rad/s\n", r.x, r.y, r.z];
            [report appendFormat:@"  grav x%+6.2f y%+6.2f z%+6.2f   acc x%+5.2f y%+5.2f z%+5.2f\n", g.x, g.y, g.z, a.x, a.y, a.z];
        }
    }

    NSArray *ips = [self localIPv4Addresses];
    [report appendFormat:@"\nNETWORK POINTER  udp port %u  bonjour %@\n", BrowserMotionPointerUDPPort, BrowserMotionPointerBonjourType];
    [report appendFormat:@"  listener: %@   TV address: %@\n", self.listenerState,
     ips.count > 0 ? [ips componentsJoinedByString:@", "] : @"(none)"];
    [report appendFormat:@"  packets:%lu  %.0f Hz  bad:%lu  flows:%lu\n",
     (unsigned long)self.networkStats.sampleCount, [self.networkStats currentHzAt:now],
     (unsigned long)self.badPackets, (unsigned long)self.connections.count];
    [report appendFormat:@"  last: %@ from %@ (%@)  dyaw%+.4f dpitch%+.4f",
     self.lastPacketType, self.lastSender, self.lastSenderName, self.lastDYaw, self.lastDPitch];
    return report;
}

#pragma mark - Overlay

- (void)installOverlay {
    UIView *rootView = self.rootView;
    if (rootView == nil) {
        return;
    }
    self.overlayView = [[UIView alloc] initWithFrame:CGRectZero];
    self.overlayView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    self.overlayView.layer.cornerRadius = 18;
    self.overlayView.userInteractionEnabled = NO;
    self.overlayView.hidden = YES;

    self.overlayLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.overlayLabel.numberOfLines = 0;
    self.overlayLabel.textColor = [UIColor colorWithRed:0.55 green:1.0 blue:0.6 alpha:1.0];
    self.overlayLabel.font = [UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightRegular];
    [self.overlayView addSubview:self.overlayLabel];
    [rootView addSubview:self.overlayView];

    [self updateOverlayVisibility];
}

- (void)updateOverlayVisibility {
    BOOL visible = self.debugOverlayVisible && self.overlayView != nil;
    self.overlayView.hidden = !visible;
    [self.overlayTimer invalidate];
    self.overlayTimer = nil;
    if (visible) {
        // Common modes, so the overlay keeps refreshing while UIKit is in a tracking run loop mode.
        self.overlayTimer = [NSTimer timerWithTimeInterval:0.25
                                                    target:self
                                                  selector:@selector(refreshOverlay)
                                                  userInfo:nil
                                                   repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.overlayTimer forMode:NSRunLoopCommonModes];
        [self refreshOverlay];
    }
}

- (void)refreshOverlay {
    UIView *rootView = self.rootView;
    if (rootView == nil || self.overlayView.hidden) {
        return;
    }
    self.overlayLabel.text = [self diagnosticReport];
    CGFloat maxWidth = MIN(1100.0, CGRectGetWidth(rootView.bounds) - 120.0);
    CGSize size = [self.overlayLabel sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat padding = 24.0;
    CGFloat height = size.height + padding * 2;
    self.overlayView.frame = CGRectMake(60.0,
                                        CGRectGetHeight(rootView.bounds) - height - 60.0,
                                        size.width + padding * 2,
                                        height);
    self.overlayLabel.frame = CGRectMake(padding, padding, size.width, size.height);
    [rootView bringSubviewToFront:self.overlayView];
}

@end
