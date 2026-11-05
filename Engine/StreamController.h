// StreamController: the resident controller for one pair of headphones. Connecting is up to the user (connectNow); otherwise it only waits for the headphones to connect to this Mac by
// themselves (powered on, or bluetoothd reconnecting after the link dropped) and grabs them then, once each time. It never retries on its own: after an attempt fails it reports why
// (LinkStatusFailed, LinkStatusBusy, LinkStatusWaitingHeadset) and waits again. When a session hands the headphones back to macOS as decided by capabilitiesHandler, it stays in
// LinkStatusSystem. Shared by the command-line serve and the menu bar app.

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
@property (nonatomic, readonly) double droppedSeconds;
@property (nonatomic, readonly) double headsetDelayMs;
@property (nonatomic, readonly, nullable) NSUUID *deviceIdentifier;

// virtualDevice: YES fetches sound from the virtual device, NO captures the whole machine's sound with a process tap
- (instancetype)initWithDevice:(IOBluetoothDevice *)device virtualDevice:(BOOL)virtualDevice;
// Start waiting for the headphones to connect by themselves (LinkStatusStandby)
- (void)start;
// Connect now, at the user's request: page the headphones and take them over (from macOS too, which forces a disconnect); starts the controller if needed.
// Replaces a session that is waiting or connecting
- (void)connectNow;
// End the current session (close the stream, hand the headphones back to macOS), then call completion
- (void)stopWithCompletion:(nullable dispatch_block_t)completion;

@end

NS_ASSUME_NONNULL_END
