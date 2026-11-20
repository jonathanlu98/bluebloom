#import "BBExperiments.h"

NSString *const BBExperimentsVisibleKey = @"BBShowExperiments";

NSString *const BBExperimentSlowABRKey = @"BBExpSlowABR";

static NSString *const kTestSuspendAfterSecondsKey = @"BBExpTestSuspendAfterSeconds";
static NSString *const kTestResumeAfterSecondsKey = @"BBExpTestResumeAfterSeconds";
static NSString *const kAutoConnectKey = @"BBExpAutoConnect";
// Retired keys kept only so resetAll clears leftovers from earlier builds
static NSString *const kRetiredLogLinkStateKey = @"BBExpLogLinkState";
static NSString *const kRetiredKeepWarmKey = @"BBExpKeepWarm";
static NSString *const kRetiredAvrcpKeepaliveKey = @"BBExpAVRCPKeepalive";
static NSString *const kRetiredAvrcpKeepaliveSecondsKey = @"BBExpAVRCPKeepaliveSeconds";
static NSString *const kRetiredLightWakeKey = @"BBExpLightWake";
static NSString *const kRetiredForceNewLinkKey = @"BBExpForceNewLink";
static NSString *const kRetiredForceNewLinkAfterSecondsKey = @"BBExpForceNewLinkAfterSeconds";
static NSString *const kRetiredHighPriorityKey = @"BBExpHighPriority";
static NSString *const kRetiredForceScanSecondsKey = @"BBExpForceScanSeconds";

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
    return @[BBExperimentSlowABRKey,
             kTestSuspendAfterSecondsKey, kTestResumeAfterSecondsKey, kAutoConnectKey,
             kRetiredLogLinkStateKey,
             kRetiredKeepWarmKey, kRetiredAvrcpKeepaliveKey, kRetiredAvrcpKeepaliveSecondsKey,
             kRetiredLightWakeKey, kRetiredForceNewLinkKey, kRetiredForceNewLinkAfterSecondsKey,
             kRetiredHighPriorityKey, kRetiredForceScanSecondsKey];
}

+ (void)resetAll {
    for (NSString *key in [self allKeys]) [Defaults() removeObjectForKey:key];
}

- (BOOL)slowABR { return [Defaults() boolForKey:BBExperimentSlowABRKey]; }
- (void)setSlowABR:(BOOL)value { [Defaults() setBool:value forKey:BBExperimentSlowABRKey]; }

- (double)testSuspendAfterSeconds { return [Defaults() doubleForKey:kTestSuspendAfterSecondsKey]; }
- (void)setTestSuspendAfterSeconds:(double)value { [Defaults() setDouble:value forKey:kTestSuspendAfterSecondsKey]; }

- (double)testResumeAfterSeconds { return Seconds(kTestResumeAfterSecondsKey, 1, kTestResumeDefaultSeconds); }
- (void)setTestResumeAfterSeconds:(double)value { [Defaults() setDouble:value forKey:kTestResumeAfterSecondsKey]; }

- (BOOL)autoConnect { return [Defaults() boolForKey:kAutoConnectKey]; }

- (NSArray<NSString *> *)activeNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (self.slowABR) [names addObject:@"slow-abr"];
    if (self.testSuspendAfterSeconds > 0) {
        [names addObject:[NSString stringWithFormat:@"test-suspend (after %.0f s, resume after %.0f s)", self.testSuspendAfterSeconds, self.testResumeAfterSeconds]];
    }
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
