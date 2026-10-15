// VolumeSync: two-way sync between the volume of the Blue Bloom virtual device and the headphones' amplifier (AVRCP absolute volume).
//   - On connect, send the Mac's current volume to the headphones (same as an iPhone does when headphones connect, avoiding a volume jump at the switch);
//   - afterwards, when the headphones' buttons change the volume, update the virtual device's volume display; when the volume changes on the Mac (keyboard, menu bar), send it to the headphones;
//   - while syncing, the driver is in hardware volume mode with no software attenuation; without an AVRCP channel it falls back to software volume.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VolumeSync : NSObject

// Called when a volume must be sent to the headphones, argument 0–127; returns NO if there is currently no AVRCP channel
@property (nonatomic, copy, nullable) BOOL (^sendVolumeHandler)(int volume);

// Volume reported by the headphones (0–127); -1 means the AVRCP channel is gone
- (void)remoteVolumeChanged:(int)volume;
// The headphones' volume up/down buttons (only sent by headphones without absolute volume support)
- (void)stepVolume:(int)direction;

@end

NS_ASSUME_NONNULL_END
