// BitrateAdapter: moves up and down between a few bitrate tiers (tier 0 is the highest) by send queue depth, for codecs without built-in adaptive bitrate (SBC, AAC and codec plugins;
// LDAC uses libldac's own ABR). Before each encode the encoder feeds in the queue depth once (packets, MediaStreamer queueDepth, normally 0;
// the streamer reports 0 for the first second after the stream opens or resumes from pause) and the audio duration of that encode, and changes encoding parameters when the tier changes.
// A backlog of ≥3 packets (about 50 ms) drops one tier, ≥6 packets drops two, then waits 0.5 seconds before looking again; 4 seconds in a row without backlog raises one tier.
// Raise backoff follows LDAC (ldac_a2dp.h ldac_abr_guard): if a raise drops back within 3 seconds, that tier is locked out, starting at 30 seconds, doubling on each failure, up to 300 seconds;
// holding at that tier or higher for 30 seconds resets it. Backoff state is kept across instances by key (reused when the stream reopens after idle suspend or after reconfiguring), and the lockout time has the wall-clock gap deducted.
// Used only on the streaming queue.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BitrateAdapter : NSObject
// name is for logging; tierKbps is each tier's bitrate (high to low); start is the starting tier; key distinguishes backoff state (usually the codec ID)
- (instancetype)initWithName:(NSString *)name tierKbps:(NSArray<NSNumber *> *)tierKbps startTier:(int)start key:(NSString *)key;
@property (nonatomic, readonly) int tier;
@property (nonatomic, readonly) double kbps;
// Highest allowed tier (media channel MTU, the limit recorded for these headphones); if the current tier is higher, drop to it immediately
@property (nonatomic) int topTier;
// Feed one queue depth; returns YES if the tier changed
- (BOOL)updateWithDepth:(NSUInteger)depth seconds:(double)seconds;
// Jump to a tier (when switching from a fixed tier to adaptive, continue from the current tier); not counted as a trial raise
- (void)jumpToTier:(int)tier;
@end

NS_ASSUME_NONNULL_END
