// AvrcpController: holds the headphones' AVRCP control channel (AVCTP, L2CAP PSM 0x17) and implements a minimal subset:
//   - as controller (CT): subscribes to the headphones' volume changes and sends absolute volume (AVRCP 1.4 Absolute Volume), keeping the Mac volume in sync with the headphones' amplifier;
//   - as target (TG): receives the headphones' play/pause/track buttons (PASS THROUGH) and reports the playback status.
// macOS cannot get this channel, so the headphones' button presses and volume changes only arrive here.

#import <Foundation/Foundation.h>
#import "ClassicXPC.h"

NS_ASSUME_NONNULL_BEGIN

// PASS THROUGH operation codes (AVC_* in BlueZ profiles/audio/avctp.h)
typedef NS_ENUM(uint8_t, AvrcpOperation) {
    AvrcpOperationVolumeUp = 0x41,
    AvrcpOperationVolumeDown = 0x42,
    AvrcpOperationPlay = 0x44,
    AvrcpOperationStop = 0x45,
    AvrcpOperationPause = 0x46,
    AvrcpOperationForward = 0x4B,
    AvrcpOperationBackward = 0x4C,
};

@interface AvrcpController : NSObject

@property (nonatomic, copy, nullable) void (^logHandler)(NSString *message);
// Absolute volume 0–127 reported by the headphones (the initial value and every later button change)
@property (nonatomic, copy, nullable) void (^volumeHandler)(int volume);
// Button pressed on the headphones (called only on press)
@property (nonatomic, copy, nullable) void (^operationHandler)(AvrcpOperation operation);
@property (nonatomic, copy, nullable) void (^closedHandler)(void);
@property (nonatomic, readonly) BOOL absoluteVolumeSupported;
// Playback status reported to the headphones; subscribed headphones are notified when it changes
@property (nonatomic) BOOL playing;

- (instancetype)initWithSocket:(L2CAPSocket *)socket;
// Query the headphones' capabilities and subscribe to volume changes if absolute volume is supported
- (void)start;
- (void)setAbsoluteVolume:(int)volume;
- (void)close;

@end

NS_ASSUME_NONNULL_END
