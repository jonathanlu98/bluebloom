// A2DPSource: one A2DP session with a pair of headphones. Grab the AVDTP signaling, HFP and AVRCP channels → query the codec
// capabilities of every headphone endpoint → pick the best usable codec and sample rate by user preference and priority →
// configure, open the media channel → stream; answer the headphones' signaling as ACP; SUSPEND on silence, START on sound;
// close the stream and reconfigure when the sample rate or codec options change; fall back by priority when a codec is unusable.

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import "A2DPCodec.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SourceMode) {
    SourceModeProbe,  // Only query capabilities, then finish
    SourceModePlay,
};

typedef NS_ENUM(NSInteger, LinkStatus) {
    LinkStatusConnecting,      // Connecting, grabbing channels
    LinkStatusWaitingHeadset,  // Headphones do not answer paging; waiting for them to power on and connect back
    LinkStatusStreaming,       // Streaming
    LinkStatusIdle,            // Connected, in idle suspend
    LinkStatusRetrying,        // Session ended, reconnecting later (StreamController)
    LinkStatusStopped,         // Disabled (StreamController)
    LinkStatusSystem,          // Headphones left for macOS to connect (in auto mode our codec is no better than the system's) (StreamController)
    LinkStatusBusy,            // Headphones refuse to open a stream: multipoint headphones are giving audio to another device; retry later (StreamController)
};

// Why the most preferred codec was not used
typedef NS_ENUM(NSInteger, CodecFallbackReason) {
    CodecFallbackNone,
    CodecFallbackUnsupportedRate,     // The codec does not support the source sample rate (e.g. a 48k-only codec with a 44.1k source)
    CodecFallbackEncoderUnavailable,  // The encoder cannot be opened
    CodecFallbackRejected,            // The headphones rejected the configuration
    CodecFallbackEncoderFailed,       // The encoder failed while streaming
    CodecFallbackEndpointBusy,        // The headphone endpoint is already in use
};

// Session exit codes
enum {
    SourceExitHandedToSystem = 10,  // Headphones handed back to macOS as decided by takeoverDecider
    // Headphones refused to open a stream or took it back (endpoint stays busy, OPEN/START refused, headphones sent CLOSE/ABORT while streaming):
    // multipoint headphones are giving audio to another device (observed 2026-10-13, WH-1000XM4 also connected to an iPhone). The controller lengthens the reconnect interval
    SourceExitHeadsetBusy = 11,
    SourceExitRetryNow = 12,        // User clicked "Retry Now": end the current session and start a new one immediately
};

// UID of the virtual device, matches kDeviceUID in Driver/BlueBloomDevice.c
extern NSString *const VirtualDeviceUID;

@interface A2DPSource : NSObject
- (instancetype)initWithDevice:(IOBluetoothDevice *)device mode:(SourceMode)mode rate:(double)rate file:(nullable NSString *)file
                       seconds:(double)seconds systemAudio:(BOOL)systemAudio;
@property (nonatomic) BOOL useVirtualDevice;
// Codec options; while streaming use updateOptions: instead
@property (nonatomic, copy) CodecOptions *options;
// Change options while streaming (e.g. the user switched codec): if the chosen codec or its parameters change, close the stream and reconfigure without disconnecting the headphones
- (void)updateOptions:(CodecOptions *)options;
// Desired sample rate (the source track's sample rate or a value fixed by the user); 0 means use the capture source's current sample rate.
// In virtual device mode the session sets the virtual device's nominal sample rate to the closest value supported by the chosen codec
@property (nonatomic) double desiredSampleRate;

// Codecs declared by all headphone endpoints (available only after capabilities are queried)
@property (nonatomic, readonly, nullable) NSArray<RemoteCodec *> *remoteCodecs;
// Current configuration (while streaming or suspended)
@property (nonatomic, readonly, nullable) CodecConfiguration *configuration;
// A codec with higher priority than the current one that was not used, and why (for the UI to explain); nil / CodecFallbackNone when all were used
@property (nonatomic, readonly, nullable) CodecID fallbackCodec;
@property (nonatomic, readonly) CodecFallbackReason fallbackReason;
// Over-the-air bitrate over the last 1 second (kbps); 0 when not streaming
@property (nonatomic, readonly) double recentKbps;
// Playback delay reported by the headphones (ms), 0 if not reported
@property (nonatomic, readonly) double headsetDelayMs;
// UUID bluetoothd assigns to these headphones (macOS uses it as the accessory identifier when publishing the headphones' power source); nil until found
@property (nonatomic, readonly, nullable) NSUUID *deviceIdentifier;

// Called after capabilities are queried (main queue), for caching and UI display; return NO to not stream and hand the headphones back to macOS (the session ends with SourceExitHandedToSystem)
@property (nonatomic, copy, nullable) BOOL (^capabilitiesHandler)(NSArray<RemoteCodec *> *codecs);
// YES when the AVRCP channel is held by the system and volume cannot be handed to the headphones' amplifier; NO once grabbed back or when the session ends (main queue).
// Does not apply when the headphones do not support absolute volume (software volume is normal then)
@property (nonatomic, copy, nullable) void (^remoteControlBlockedHandler)(BOOL blocked);
// Called when we find at runtime that the headphones cannot take a high bitrate of some codec (main queue), giving the highest bitrate (kbps) to use from now on, to be stored per device (and passed back later via options.maxKbps)
@property (nonatomic, copy, nullable) void (^codecLimitHandler)(CodecID codec, double maxKbps);
// Called when the session ends (instead of the default exit); serve mode and the app use it to start a new session in the same process
@property (nonatomic, copy, nullable) void (^terminationHandler)(int exitCode);
// Called on status changes (main queue), for display in the app
@property (nonatomic, copy, nullable) void (^statusHandler)(LinkStatus status, double sampleRate, int batteryPercent);
// When the headphones' AVRCP channel is grabbed and they support absolute volume, reports headphone volume 0–127; reports -1 when the AVRCP channel is lost
@property (nonatomic, copy, nullable) void (^remoteVolumeHandler)(int volume);
// Headphone button presses (AvrcpOperation values)
@property (nonatomic, copy, nullable) void (^remoteOperationHandler)(uint8_t operation);
// Set headphone volume 0–127 via AVRCP; returns NO when there is no AVRCP channel
- (BOOL)setRemoteVolume:(int)volume;
- (void)start;
- (void)stopWithReason:(NSString *)reason exitCode:(int)exitCode;
@end

NS_ASSUME_NONNULL_END
