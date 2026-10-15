// SourceRateMonitor: reads the actual sample rate and bit depth of the current track from Apple Music's log.
// Each time Music selects an audio format it logs a line (observed 2026-10-12, macOS 27):
//   activeFormat: tier: Lossless; groupID: audio-alac-stereo-96000-24; bitDepth: 24-bit; sampleRate: 96khz; ...
// Reading the system log requires the current user to be an administrator (a /usr/bin/log requirement).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SourceRateMonitor : NSObject

// Main-queue callback: sample rate (Hz), bit depth (0 if unknown)
@property (nonatomic, copy, nullable) void (^formatHandler)(double sampleRate, int bitDepth);
// Main-queue callback: each time Music creates a lossless decoder it logs "ACAppleLosslessDecoder ... Input format: 2 ch, 96000 Hz, alac ... from 24-bit source",
// giving the sample rate, bit depth and log time. The preloaded next track creates one too, so the caller must match it to the current track by time and sample rate (only used to fill in the bit depth)
@property (nonatomic, copy, nullable) void (^decoderHandler)(double sampleRate, int bitDepth, NSDate *date);

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
