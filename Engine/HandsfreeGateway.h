// HandsfreeGateway: holds the headphones' hands-free (HFP) RFCOMM channel and plays a minimal audio gateway (AG) itself.
// If macOS cannot connect HFP, it does not publish the headphones' call device, and no program can make it open SCO (SCO permanently takes airtime, leaving aptX only 200–280kbps).
// Only answers the AT commands needed to establish the service level connection (SLC) and common harmless commands; calls, incoming calls and the microphone are not supported.

#import <Foundation/Foundation.h>
#import "ClassicXPC.h"

NS_ASSUME_NONNULL_BEGIN

@interface HandsfreeGateway : NSObject

@property (nonatomic, copy, nullable) void (^logHandler)(NSString *message);
@property (nonatomic, copy, nullable) void (^closedHandler)(void);
@property (nonatomic, copy, nullable) void (^batteryHandler)(int percent);
@property (nonatomic, readonly) BOOL serviceLevelConnected;
// Battery level reported by the headphones via AT+IPHONEACCEV or AT+BIEV, 0–100; -1 when not reported
@property (nonatomic, readonly) int batteryPercent;

- (instancetype)initWithSocket:(L2CAPSocket *)socket;
- (void)close;

@end

NS_ASSUME_NONNULL_END
