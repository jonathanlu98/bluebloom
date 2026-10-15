// SystemAudio: captures the sound to stream to the headphones, from one of two sources:
//   - process tap (macOS 14.2+) captures the whole machine's output; the built-in speakers are muted while capturing;
//   - virtual device (Driver/BlueBloomDevice.c): the user picks this device in Sound settings, the driver buffers what apps play, and this class periodically fetches it through a custom property.

#import <Foundation/Foundation.h>
#import "PCMSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface SystemAudioSource : NSObject <PCMSource>

@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) NSString *formatDescription;
@property (nonatomic, readonly) uint64_t capturedFrames;
@property (nonatomic, readonly) uint64_t droppedFrames;
@property (nonatomic, readonly) uint64_t silentReads;
// Seconds since the last non-zero sample was captured; seconds since start if there has never been sound
@property (nonatomic, readonly) double secondsSinceSound;
// Called (on the main queue) when the device's nominal sample rate changes in virtual device mode
@property (nonatomic, copy, nullable) void (^sampleRateChangedHandler)(double rate);

- (nullable instancetype)initWithError:(NSString *_Nullable *_Nullable)error;
// Fetch sound from the virtual device (does not open an input, needs no microphone permission)
- (nullable instancetype)initWithDeviceUID:(NSString *)uid error:(NSString *_Nullable *_Nullable)error;
// The virtual device's current nominal sample rate (read live; returns sampleRate in process tap mode)
@property (nonatomic, readonly) double deviceSampleRate;
// Ask the virtual device to change its nominal sample rate (the driver goes through a configuration change, which takes effect later and fires sampleRateChangedHandler); returns NO in process tap mode
- (BOOL)setDeviceSampleRate:(double)rate;
- (BOOL)start:(NSString *_Nullable *_Nullable)error;
- (void)stop;
// Called periodically while streaming is paused: drops old data and keeps only a short recent stretch (not counted as dropped), used as the leading pre-roll on resume
- (void)keepRecentOnly;

@end

NS_ASSUME_NONNULL_END
