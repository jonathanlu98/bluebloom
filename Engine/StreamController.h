// StreamController: the resident controller. Keeps an A2DP session with one pair of headphones alive: after a session ends (headphones powered off, out of range, failure) it starts a new one a few seconds later;
// when a session hands the headphones back to macOS as decided by capabilitiesHandler, it stays in LinkStatusSystem and does not reconnect. Shared by the command-line serve and the menu bar app.

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import "A2DPSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface StreamController : NSObject

@property (nonatomic, readonly) IOBluetoothDevice *device;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) LinkStatus status;
// Called when the status changes (main queue)
@property (nonatomic, copy, nullable) void (^statusHandler)(LinkStatus status, double sampleRate, int batteryPercent);

// Headphones volume 0–127 (AVRCP absolute volume); -1 means there is currently no AVRCP channel
@property (nonatomic, copy, nullable) void (^remoteVolumeHandler)(int volume);
// Headphones button press (an AvrcpOperation value)
@property (nonatomic, copy, nullable) void (^remoteOperationHandler)(uint8_t operation);
// Set the headphones volume via AVRCP; returns NO when there is no AVRCP channel
- (BOOL)setRemoteVolume:(int)volume;

// Called before each session starts to provide the codec options for these headphones; default options are used if unset
@property (nonatomic, copy, nullable) CodecOptions *_Nonnull (^optionsProvider)(void);
// Called when the headphones' capabilities are known (see A2DPSource.capabilitiesHandler); returning NO hands the headphones back to macOS
@property (nonatomic, copy, nullable) BOOL (^capabilitiesHandler)(NSArray<RemoteCodec *> *codecs);
// The AVRCP channel is held by macOS, so volume cannot be handed to the headphones' amplifier (see A2DPSource.remoteControlBlockedHandler)
@property (nonatomic, copy, nullable) void (^remoteControlBlockedHandler)(BOOL blocked);
// Found while running that the headphones cannot take a high bitrate for some codec (see A2DPSource.codecLimitHandler)
@property (nonatomic, copy, nullable) void (^codecLimitHandler)(CodecID codec, double maxKbps);
// Change codec options while streaming (without disconnecting the headphones; closes and reconfigures the stream if needed)
- (void)updateOptions:(CodecOptions *)options NS_SWIFT_NAME(updateOptions(_:));
// Desired sample rate (the source track's sample rate or a value fixed by the user); 0 means unspecified
@property (nonatomic) double desiredSampleRate;

// Information about the current session (see the A2DPSource properties of the same names)
@property (nonatomic, readonly, nullable) CodecConfiguration *configuration;
@property (nonatomic, readonly, nullable) NSArray<RemoteCodec *> *remoteCodecs;
@property (nonatomic, readonly, nullable) CodecID fallbackCodec;
@property (nonatomic, readonly) CodecFallbackReason fallbackReason;
@property (nonatomic, readonly) double recentKbps;
@property (nonatomic, readonly) double headsetDelayMs;
@property (nonatomic, readonly, nullable) NSUUID *deviceIdentifier;

// virtualDevice: YES fetches sound from the virtual device, NO captures the whole machine's sound with a process tap
- (instancetype)initWithDevice:(IOBluetoothDevice *)device virtualDevice:(BOOL)virtualDevice;
- (void)start;
// End the current session (close the stream, hand the headphones back to macOS), then call completion
- (void)stopWithCompletion:(nullable dispatch_block_t)completion;
// Time of the next automatic reconnect (in LinkStatusRetrying, LinkStatusBusy); nil when none is scheduled
@property (nonatomic, readonly, nullable) NSDate *nextAttempt;
// Retry now: start immediately while waiting to reconnect; if the session is still waiting for the headphones to answer, end it and start again. Also clears the "headphones busy" backoff
- (void)retryNow;

@end

NS_ASSUME_NONNULL_END
