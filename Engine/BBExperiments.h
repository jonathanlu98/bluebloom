// Experiment switches for investigating dropouts. None of this is product behavior: every switch is off by default and
// none has been shown to prevent dropouts. The values live in NSUserDefaults under the keys below. The app and the
// command-line tool each keep their own: the app's (domain app.bluebloom) are set in its hidden Settings › Advanced ›
// Experiments section, the tool's (app.bluebloom.cli) with its flags, and `defaults write <domain> <key>` reaches either.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Whether the app shows the Experiments section (Option-click the version in Settings › About). Not an experiment itself:
// resetAll leaves it alone
extern NSString *const BBExperimentsVisibleKey;

extern NSString *const BBExperimentSlowABRKey;

@interface BBExperiments : NSObject

@property (class, readonly) BBExperiments *shared;

// While streaming
// Always use slow adaptive bitrate recovery (BitrateAdapter) even off 2.4 GHz Wi-Fi (automatic on 2.4 GHz)
@property (nonatomic) BOOL slowABR;

// Test harness, set from the command line or with `defaults write` only
// Suspend this many seconds after START (0 = off) and resume testResumeAfterSeconds later, once per session, so a run does
// not depend on the audio source going silent
@property (nonatomic) double testSuspendAfterSeconds;    // default 0
@property (nonatomic) double testResumeAfterSeconds;     // default 20, at least 1
// App only: connect on launch without waiting for the headphones to connect by themselves (BBExpAutoConnect)
@property (nonatomic, readonly) BOOL autoConnect;

// The switches that differ from their defaults, for the log and the diagnostics summary: "none", or for example
// "slow-abr"
@property (nonatomic, readonly) NSString *summary;
// Number of switches that are on (the test harness values count too)
@property (nonatomic, readonly) NSInteger activeCount;

// Puts every switch and value back to its default
+ (void)resetAll;

@end

NS_ASSUME_NONNULL_END
