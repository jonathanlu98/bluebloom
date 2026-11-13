// Experiment switches for investigating dropouts. None of this is product behavior: every switch is off by default and
// none has been shown to prevent dropouts. The values live in NSUserDefaults under the keys below. The app and the
// command-line tool each keep their own: the app's (domain app.bluebloom) are set in its hidden Settings › Advanced ›
// Experiments section, the tool's (app.bluebloom.cli) with its flags, and `defaults write <domain> <key>` reaches either.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Whether the app shows the Experiments section (Option-click the version in Settings › About). Not an experiment itself:
// resetAll leaves it alone
extern NSString *const BBExperimentsVisibleKey;

extern NSString *const BBExperimentKeepWarmKey;
extern NSString *const BBExperimentAvrcpKeepaliveKey;
extern NSString *const BBExperimentAvrcpKeepaliveSecondsKey;
extern NSString *const BBExperimentLightWakeKey;
extern NSString *const BBExperimentForceNewLinkKey;
extern NSString *const BBExperimentForceNewLinkAfterSecondsKey;
extern NSString *const BBExperimentSlowABRKey;
extern NSString *const BBExperimentHighPriorityKey;
extern NSString *const BBExperimentLogLinkStateKey;

// Defaults and lower limits of the two intervals, for the settings fields
extern const double BBExperimentAvrcpKeepaliveDefaultSeconds;
extern const double BBExperimentForceNewLinkDefaultSeconds;
extern const double BBExperimentMinimumSeconds;

@interface BBExperiments : NSObject

@property (class, readonly) BBExperiments *shared;

// While paused
// Do not SUSPEND after silence: keep the stream open and keep sending silence
@property (nonatomic) BOOL keepWarm;
// While the stream is suspended, send an AVRCP GetCapabilities request every avrcpKeepaliveSeconds
@property (nonatomic) BOOL avrcpKeepalive;
@property (nonatomic) double avrcpKeepaliveSeconds;      // default 60, at least 5
// When sound comes back, send an AVRCP request and wait 0.3 s before START
@property (nonatomic) BOOL lightWake;
// When sound comes back after forceNewLinkAfterSeconds or longer, disconnect and start a new session instead of START
@property (nonatomic) BOOL forceNewLink;
@property (nonatomic) double forceNewLinkAfterSeconds;   // default 600, at least 5

// While streaming
// Adaptive bitrate (BitrateAdapter) waits much longer before trying a higher tier again, and after a failed attempt
@property (nonatomic) BOOL slowABR;
// Ask the Bluetooth controller to give the headphones' link high priority while streaming
@property (nonatomic) BOOL highPriority;

// Extra log lines around resume and the priority request
@property (nonatomic) BOOL logLinkState;

// Test harness, set from the command line or with `defaults write` only
// Suspend this many seconds after START (0 = off) and resume testResumeAfterSeconds later, once per session, so a run does
// not depend on the audio source going silent
@property (nonatomic) double testSuspendAfterSeconds;    // default 0
@property (nonatomic) double testResumeAfterSeconds;     // default 20, at least 1
// At START, ask a Broadcom controller for a 75% duty-cycle LE scan for this many seconds (0 = off)
@property (nonatomic) double forceScanSeconds;           // default 0
// App only: connect on launch without waiting for the headphones to connect by themselves (BBExpAutoConnect)
@property (nonatomic, readonly) BOOL autoConnect;

// The switches that differ from their defaults, for the log and the diagnostics summary: "none", or for example
// "avrcp-keepalive (30 s), high-priority"
@property (nonatomic, readonly) NSString *summary;
// Number of switches that are on (the test harness values count too)
@property (nonatomic, readonly) NSInteger activeCount;

// Puts every switch and value back to its default
+ (void)resetAll;

@end

NS_ASSUME_NONNULL_END
