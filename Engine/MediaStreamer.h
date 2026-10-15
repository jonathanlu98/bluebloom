// MediaStreamer: hands PCM to the encoder and writes media packets into the media channel, paced by the sample clock (test tone, file) or by the capture cadence (system audio, virtual device).
// Runs on its own high-priority serial queue, unaffected by main-thread (UI, signaling) stalls; callbacks return to the main queue.

#import <Foundation/Foundation.h>
#import "A2DPCodec.h"
#import "ClassicXPC.h"
#import "PCMSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface MediaStreamer : NSObject
// Called when the source runs out (test tone, file)
@property (nonatomic, copy, nullable) void (^finishedHandler)(void);
// Called when the encoder fails; streaming stops afterwards
@property (nonatomic, copy, nullable) void (^failureHandler)(NSString *reason);
// Called once (main queue) when nothing can be written into the media channel for several seconds in a row (the headphones stopped accepting data); the stream is kept and the upper layer decides whether to rebuild it; may fire again after writes resume.
// maxKbps is the highest bitrate the encoder believes the headphones can take (A2DPEncoder mediaStalled); 0 means bitrate is not the problem
@property (nonatomic, copy, nullable) void (^stallHandler)(double maxKbps);
// Bitrate actually written into the media channel over the last second (kbps, including RTP headers); readable from any thread
@property (nonatomic, readonly) double recentKbps;
@property (nonatomic, readonly) id<A2DPEncoder> encoder;

- (instancetype)initWithSocket:(L2CAPSocket *)socket rate:(double)rate source:(id<PCMSource>)source
                       encoder:(id<A2DPEncoder>)encoder label:(NSString *)label;
- (void)start;
// Swap encoders while streaming (same stream, only the encoding parameters change, e.g. LDAC tier, AAC bitrate): factory runs on the streaming queue, and the old encoder is not encoding while it runs
// (only one SBC encoder instance can exist globally; creating a new one invalidates the old one). Packets already encoded and waiting are still sent; RTP sequence numbers and timestamps continue on. If factory returns nil nothing is swapped and this returns NO
- (BOOL)replaceEncoderWith:(id<A2DPEncoder> _Nullable (^)(void))factory;
// Have the current encoder switch to new parameters in place (A2DPEncoder applyConfiguration:, run on the streaming queue); returns NO if the encoder does not support it
- (BOOL)applyConfiguration:(CodecConfiguration *)configuration;
// On return, nothing more will be sent on the streaming queue (the socket can then be closed safely)
- (void)pause;
- (void)logTotals;
@end

NS_ASSUME_NONNULL_END
