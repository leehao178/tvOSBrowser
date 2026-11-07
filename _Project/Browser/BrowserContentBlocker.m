#import "BrowserContentBlocker.h"

#import <objc/message.h>

// Domain list adapted from Webby (https://github.com/jleybourne/Webby, MIT License).

static NSString * const kBrowserAdBlockEnabledKey = @"BrowserAdBlockEnabled";
static NSString * const kBrowserContentRuleListIdentifier = @"BrowserAdBlockRules-v1";

@interface BrowserContentBlocker ()

@property (nonatomic, strong) NSHashTable *controllers;
@property (nullable, nonatomic, strong) id ruleList;
@property (nonatomic) BOOL compiling;

@end

@implementation BrowserContentBlocker

+ (instancetype)sharedBlocker {
    static BrowserContentBlocker *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[BrowserContentBlocker alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _controllers = [NSHashTable weakObjectsHashTable];
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{kBrowserAdBlockEnabledKey: @YES}];
    }
    return self;
}

#pragma mark - Public

- (BOOL)isEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kBrowserAdBlockEnabledKey];
}

- (void)setEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kBrowserAdBlockEnabledKey];
    for (id controller in self.controllers.allObjects) {
        [self applyToController:controller];
    }
}

- (BOOL)isReady {
    return self.ruleList != nil;
}

- (void)attachToUserContentController:(id)userContentController {
    if (userContentController == nil) {
        return;
    }
    [self.controllers addObject:userContentController];
    [self compileIfNeeded];
    [self applyToController:userContentController];
}

#pragma mark - Rule list

- (void)applyToController:(id)controller {
    if (self.ruleList == nil) {
        return;
    }
    // Remove first so repeated calls never add the same list twice.
    SEL removeSelector = NSSelectorFromString(@"removeContentRuleList:");
    if ([controller respondsToSelector:removeSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, removeSelector, self.ruleList);
    }
    if (!self.enabled) {
        return;
    }
    SEL addSelector = NSSelectorFromString(@"addContentRuleList:");
    if ([controller respondsToSelector:addSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addSelector, self.ruleList);
    }
}

- (void)compileIfNeeded {
    if (self.ruleList != nil || self.compiling) {
        return;
    }

    Class storeClass = NSClassFromString(@"WKContentRuleListStore");
    SEL defaultStoreSelector = NSSelectorFromString(@"defaultStore");
    if (storeClass == Nil || ![storeClass respondsToSelector:defaultStoreSelector]) {
        NSLog(@"[AdBlock] WKContentRuleListStore is not available on this system.");
        return;
    }
    id store = ((id (*)(id, SEL))objc_msgSend)((id)storeClass, defaultStoreSelector);
    SEL compileSelector = NSSelectorFromString(@"compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:");
    if (store == nil || ![store respondsToSelector:compileSelector]) {
        NSLog(@"[AdBlock] Content rule list compilation is not available.");
        return;
    }

    NSString *encodedRules = [[self class] encodedRuleList];
    if (encodedRules == nil) {
        return;
    }

    self.compiling = YES;
    __weak typeof(self) weakSelf = self;
    void (^completion)(id, NSError *) = ^(id ruleList, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf.compiling = NO;
            if (ruleList == nil) {
                NSLog(@"[AdBlock] Failed to compile rules: %@", error);
                return;
            }
            strongSelf.ruleList = ruleList;
            NSLog(@"[AdBlock] Compiled %lu blocking rules.", (unsigned long)[[strongSelf class] blockedDomains].count);
            for (id controller in strongSelf.controllers.allObjects) {
                [strongSelf applyToController:controller];
            }
        });
    };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, compileSelector, kBrowserContentRuleListIdentifier, encodedRules, completion);
}

+ (nullable NSString *)encodedRuleList {
    NSMutableArray *rules = [NSMutableArray array];
    for (NSString *domain in [self blockedDomains]) {
        NSString *escaped = [domain stringByReplacingOccurrencesOfString:@"." withString:@"\\."];
        // Matches the domain and any subdomain. "third-party" means the page you
        // navigated to yourself is never blocked, only resources it loads.
        NSString *filter = [NSString stringWithFormat:@"^https?://+([^:/]+\\.)?%@[:/]", escaped];
        [rules addObject:@{
            @"trigger": @{
                @"url-filter": filter,
                @"load-type": @[@"third-party"],
            },
            @"action": @{@"type": @"block"},
        }];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:rules options:0 error:nil];
    return data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

+ (NSArray<NSString *> *)blockedDomains {
    static NSArray<NSString *> *domains = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        domains = @[
            @"doubleclick.net", @"googlesyndication.com", @"googleadservices.com", @"adservice.google.com",
            @"pagead2.googlesyndication.com", @"tpc.googlesyndication.com", @"adnxs.com", @"adsrvr.org",
            @"advertising.com", @"amazon-adsystem.com", @"criteo.com", @"criteo.net",
            @"taboola.com", @"outbrain.com", @"revcontent.com", @"mgid.com",
            @"pubmatic.com", @"rubiconproject.com", @"openx.net", @"casalemedia.com",
            @"indexww.com", @"smartadserver.com", @"teads.tv", @"media.net",
            @"contextweb.com", @"sharethrough.com", @"triplelift.com", @"yieldmo.com",
            @"33across.com", @"gumgum.com", @"adform.net", @"adition.com",
            @"bidswitch.net", @"spotxchange.com", @"spotx.tv", @"springserve.com",
            @"lijit.com", @"sovrn.com", @"zedo.com", @"adtech.de",
            @"yieldlab.net", @"rlcdn.com", @"adsafeprotected.com", @"moatads.com",
            @"doubleverify.com", @"serving-sys.com", @"flashtalking.com", @"innovid.com",
            @"imasdk.googleapis.com", @"popads.net", @"popcash.net", @"propellerads.com",
            @"adcash.com", @"exoclick.com", @"juicyads.com", @"trafficjunky.net",
            @"adsterra.com", @"hilltopads.net", @"admaven.com", @"clickadu.com",
            @"infolinks.com", @"buysellads.com", @"carbonads.net", @"adroll.com",
            @"quantserve.com", @"quantcount.com", @"zergnet.com", @"yahoo-ads.com",
            @"ads.yahoo.com", @"advertising.yahoo.com", @"ads.twitter.com", @"ads-twitter.com",
            @"ads.linkedin.com", @"adsymptotic.com", @"unrulymedia.com", @"undertone.com",
            @"kargo.com", @"districtm.io", @"emxdgt.com", @"onetag-sys.com",
            @"smaato.net", @"inmobi.com", @"applovin.com", @"unityads.unity3d.com",
            @"vungle.com", @"chartboost.com", @"ironsrc.com", @"adcolony.com",
            @"mopub.com", @"google-analytics.com", @"googletagmanager.com", @"googletagservices.com",
            @"ssl.google-analytics.com", @"analytics.google.com", @"stats.g.doubleclick.net", @"scorecardresearch.com",
            @"comscore.com", @"chartbeat.com", @"chartbeat.net", @"hotjar.com",
            @"hotjar.io", @"mouseflow.com", @"crazyegg.com", @"fullstory.com",
            @"mixpanel.com", @"segment.io", @"segment.com", @"amplitude.com",
            @"heapanalytics.com", @"kissmetrics.com", @"optimizely.com", @"newrelic.com",
            @"nr-data.net", @"bugsnag.com", @"branch.io", @"app-measurement.com",
            @"adjust.com", @"appsflyer.com", @"kochava.com", @"bluekai.com",
            @"krxd.net", @"demdex.net", @"omtrdc.net", @"everesttech.net",
            @"exelator.com", @"eyeota.net", @"tapad.com", @"agkn.com",
            @"mathtag.com", @"addthis.com", @"addthisedge.com", @"sharethis.com",
            @"bounceexchange.com", @"connect.facebook.net", @"pixel.facebook.com", @"an.facebook.com",
            @"analytics.tiktok.com", @"ads.tiktok.com", @"bat.bing.com", @"clarity.ms",
            @"pixel.wp.com", @"stats.wp.com", @"yandex.ru", @"mc.yandex.ru",
            @"an.yandex.ru", @"statcounter.com", @"histats.com", @"luckyorange.com",
            @"inspectlet.com", @"clicktale.net", @"contentsquare.net", @"permutive.com",
            @"parsely.com", @"parse.ly", @"piano.io", @"tinypass.com",
            @"cxense.com", @"gemius.pl", @"webtrends.com", @"omniture.com",
            @"2o7.net", @"coremetrics.com", @"tealiumiq.com", @"tiqcdn.com",
            @"ensighten.com", @"onesignal.com", @"pushcrew.com", @"pushwoosh.com",
            @"subscribers.com", @"liadm.com", @"id5-sync.com", @"crwdcntrl.net",
            @"adsymptotic.net", @"zemanta.com",
        ];
    });
    return domains;
}

@end
