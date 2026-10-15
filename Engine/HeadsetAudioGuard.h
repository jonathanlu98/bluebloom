// HeadsetAudioGuard: keeps macOS from using the headphones through the call channel (HFP).
// After A2DP is grabbed, bluetoothd still connects HFP, and coreaudiod may publish it as "<address>:output" / "<address>:input"
// and make them the temporary default input/output. As soon as any program uses it, the SCO link opens and permanently takes airtime, leaving aptX only 200–280kbps (observed 2026-10-12).
// The guard switches the default device back to the original one whenever it gets switched over. The real fix is taking over the hands-free channel (HandsfreeGateway); the guard is only a fallback when that fails.
// Hog mode is not used: observed on macOS 27 that after hogging, other processes still read HogMode as -1 and can start IO on the device anyway.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HeadsetAudioGuard : NSObject

@property (nonatomic, copy, nullable) void (^logHandler)(NSString *message);

// address: Bluetooth address, separated by either "-" or ":"
- (instancetype)initWithAddress:(NSString *)address;
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
