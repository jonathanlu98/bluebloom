#import "BBExperiments.h"

NSString *const BBExperimentsVisibleKey = @"BBShowExperiments";

NSString *const BBExperimentKeepWarmKey = @"BBExpKeepWarm";
NSString *const BBExperimentAvrcpKeepaliveKey = @"BBExpAVRCPKeepalive";
NSString *const BBExperimentAvrcpKeepaliveSecondsKey = @"BBExpAVRCPKeepaliveSeconds";
NSString *const BBExperimentLightWakeKey = @"BBExpLightWake";
NSString *const BBExperimentForceNewLinkKey = @"BBExpForceNewLink";
NSString *const BBExperimentForceNewLinkAfterSecondsKey = @"BBExpForceNewLinkAfterSeconds";
NSString *const BBExperimentSlowABRKey = @"BBExpSlowABR";
NSString *const BBExperimentHighPriorityKey = @"BBExpHighPriority";
NSString *const BBExperimentLogLinkStateKey = @"BBExpLogLinkState";

static NSString *const kTestSuspendAfterSecondsKey = @"BBExpTestSuspendAfterSeconds";
static NSString *const kTestResumeAfterSecondsKey = @"BBExpTestResumeAfterSeconds";
static NSString *const kForceScanSecondsKey = @"BBExpForceScanSeconds";
static NSString *const kAutoConnectKey = @"BBExpAutoConnect";

const double BBExperimentAvrcpKeepaliveDefaultSeconds = 60;
const double BBExperimentForceNewLinkDefaultSeconds = 600;
const double BBExperimentMinimumSeconds = 5;
static const double kTestResumeDefaultSeconds = 20;

static NSUserDefaults *Defaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

// A stored interval, or the default when it is missing or below the minimum
static double Seconds(NSString *key, double minimum, double fallback) {
    double seconds = [Defaults() doubleForKey:key];
    return seconds >= minimum ? seconds : fallback;
}

@implementation BBExperiments

+ (BBExperiments *)shared {
    static BBExperiments *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [BBExperiments new]; });
    return shared;
}

+ (NSArray<NSString *> *)allKeys {
    return @[BBExperimentKeepWarmKey, BBExperimentAvrcpKeepaliveKey, BBExperimentAvrcpKeepaliveSecondsKey, BBExperimentLightWakeKey,
             BBExperimentForceNewLinkKey, BBExperimentForceNewLinkAfterSecondsKey, BBExperimentSlowABRKey, BBExperimentHighPriorityKey,
             BBExperimentLogLinkStateKey, kTestSuspendAfterSecondsKey, kTestResumeAfterSecondsKey, kForceScanSecondsKey, kAutoConnectKey];
}

+ (void)resetAll {
    for (NSString *key in [self allKeys]) [Defaults() removeObjectForKey:key];
}

- (BOOL)keepWarm { return [Defaults() boolForKey:BBExperimentKeepWarmKey]; }
- (void)setKeepWarm:(BOOL)value { [Defaults() setBool:value forKey:BBExperimentKeepWarmKey]; }

- (BOOL)avrcpKeepalive { return [Defaults() boolForKey:BBExperimentAvrcpKeepaliveKey]; }
- (void)setAvrcpKeepalive:(BOOL)value { [Defaults() setBool:value forKey:BBExperimentAvrcpKeepaliveKey]; }

- (double)avrcpKeepaliveSeconds {
    return Seconds(BBExperimentAvrcpKeepaliveSecondsKey, BBExperimentMinimumSeconds, BBExperimentAvrcpKeepaliveDefaultSeconds);
}
- (void)setAvrcpKeepaliveSeconds:(double)value { [Defaults() setDouble:value forKey:BBExperimentAvrcpKeepaliveSecondsKey]; }

- (BOOL)lightWake { return [Defaults() boolForKey:BBExperimentLightWakeKey]; }
- (void)setLightWake:(BOOL)value { [Defaults() setBool:value forKey:BBExperimentLightWakeKey]; }

- (BOOL)forceNewLink { return [Defaults() boolForKey:BBExperimentForceNewLinkKey]; }
- (void)setForceNewLink:(BOOL)value { [Defaults() setBool:value forKey:BBExperimentForceNewLinkKey]; }

- (double)forceNewLinkAfterSeconds {
    return Seconds(BBExperimentForceNewLinkAfterSecondsKey, BBExperimentMinimumSeconds, BBExperimentForceNewLinkDefaultSeconds);
}
- (void)setForceNewLinkAfterSeconds:(double)value { [Defaults() setDouble:value forKey:BBExperimentForceNewLinkAfterSecondsKey]; }

- (BOOL)slowABR { return [Defaults() boolForKey:BBExperimentSlowABRKey]; }
- (void)setSlowABR:(BOOL)value { [Defaults() setBool:value forKey:BBExperimentSlowABRKey]; }

- (BOOL)highPriority { return [Defaults() boolForKey:BBExperimentHighPriorityKey]; }
- (void)setHighPriority:(BOOL)value { [Defaults() setBool:value forKey:BBExperimentHighPriorityKey]; }

- (BOOL)logLinkState { return [Defaults() boolForKey:BBExperimentLogLinkStateKey]; }
- (void)setLogLinkState:(BOOL)value { [Defaults() setBool:value forKey:BBExperimentLogLinkStateKey]; }

- (double)testSuspendAfterSeconds { return [Defaults() doubleForKey:kTestSuspendAfterSecondsKey]; }
- (void)setTestSuspendAfterSeconds:(double)value { [Defaults() setDouble:value forKey:kTestSuspendAfterSecondsKey]; }

- (double)testResumeAfterSeconds { return Seconds(kTestResumeAfterSecondsKey, 1, kTestResumeDefaultSeconds); }
- (void)setTestResumeAfterSeconds:(double)value { [Defaults() setDouble:value forKey:kTestResumeAfterSecondsKey]; }

- (double)forceScanSeconds { return [Defaults() doubleForKey:kForceScanSecondsKey]; }
- (void)setForceScanSeconds:(double)value { [Defaults() setDouble:value forKey:kForceScanSecondsKey]; }

- (BOOL)autoConnect { return [Defaults() boolForKey:kAutoConnectKey]; }

- (NSArray<NSString *> *)activeNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (self.keepWarm) [names addObject:@"keep-warm"];
    if (self.avrcpKeepalive) [names addObject:[NSString stringWithFormat:@"avrcp-keepalive (%.0f s)", self.avrcpKeepaliveSeconds]];
    if (self.lightWake) [names addObject:@"light-wake"];
    if (self.forceNewLink) [names addObject:[NSString stringWithFormat:@"force-new-link (after %.0f s)", self.forceNewLinkAfterSeconds]];
    if (self.slowABR) [names addObject:@"slow-abr"];
    if (self.highPriority) [names addObject:@"high-priority"];
    if (self.logLinkState) [names addObject:@"log-link-state"];
    if (self.testSuspendAfterSeconds > 0) {
        [names addObject:[NSString stringWithFormat:@"test-suspend (after %.0f s, resume after %.0f s)", self.testSuspendAfterSeconds, self.testResumeAfterSeconds]];
    }
    if (self.forceScanSeconds > 0) [names addObject:[NSString stringWithFormat:@"force-scan (%.0f s)", self.forceScanSeconds]];
    if (self.autoConnect) [names addObject:@"auto-connect"];
    return names;
}

- (NSString *)summary {
    NSArray<NSString *> *names = [self activeNames];
    return names.count ? [names componentsJoinedByString:@", "] : @"none";
}

- (NSInteger)activeCount {
    return (NSInteger)[self activeNames].count;
}

@end
