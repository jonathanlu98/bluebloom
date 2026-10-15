// ClassicXPC: bypasses IOBluetooth and talks directly to bluetoothd's classic Bluetooth XPC service to get raw sockets for L2CAP channels.
// The protocol comes from tools/xpctrace.c recordings of what IOBluetooth actually sends and receives (macOS 27.0 / 26A428, 2026-10-12); it is a private interface and may change with system updates.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ChannelOpenHandler)(int result, uint16_t cid, uint16_t outMTU, int fd);
// service16: the peer service's 16-bit UUID (kCBMsgArgServiceUUID in the event), 0 when it is not 16-bit
typedef void (^RFCOMMOpenHandler)(int result, uint16_t mtu, uint16_t service16, int fd);

// One XPC connection = one session in bluetoothd; bluetoothd allows only one channel at a time per session and device (observed "Already connected to device")
@interface ClassicSession : NSObject

@property (nonatomic, readonly) NSString *label;
@property (nonatomic, readonly) BOOL openInFlight;
@property (nonatomic, readonly) BOOL rfcommInFlight;
@property (nonatomic, readonly) BOOL ready;
@property (nonatomic, copy, nullable) void (^channelClosedHandler)(uint16_t psm, int result);
// A connection established by any device (message 51) is sent to the session, with kCBMsgArgDeviceUUID in the arguments identifying the device (observed 2026-10-13: this event, received while paging the XM4
// was failing, was actually Bathys connecting); callers must check it themselves
@property (nonatomic, copy, nullable) void (^peerConnectedHandler)(NSUUID *_Nullable device);
@property (nonatomic, copy, nullable) void (^rfcommClosedHandler)(uint8_t channel, int result);

- (instancetype)initWithLabel:(NSString *)label;
// Runs (on the main queue) once check-in is done and the "Bluetooth powered on" state has arrived
- (void)whenReady:(dispatch_block_t)block;
- (nullable NSUUID *)lookupAddress:(NSString *)address;
- (void)connectDevice:(NSUUID *)device;
- (void)cancelConnection:(NSUUID *)device;
- (void)openChannel:(NSUUID *)device psm:(uint16_t)psm handler:(ChannelOpenHandler)handler;
// priority is written to the option kCBL2CAPChannelPriority (a key name found in bluetoothd strings; the meaning of its values is undocumented and was worked out by observation)
- (void)openChannel:(NSUUID *)device psm:(uint16_t)psm priority:(int64_t)priority handler:(ChannelOpenHandler)handler;
- (void)closeChannel:(NSUUID *)device psm:(uint16_t)psm;
- (void)openRFCOMM:(NSUUID *)device channel:(uint8_t)channel handler:(RFCOMMOpenHandler)handler;
- (void)closeRFCOMM:(NSUUID *)device channel:(uint8_t)channel;
- (void)invalidate;

@end

// Channel socket bluetoothd hands to the client (shared by L2CAP and RFCOMM): SOCK_STREAM, so L2CAP message boundaries must be split by the caller
@interface L2CAPSocket : NSObject

@property (nonatomic, readonly) int fd;
@property (nonatomic, readonly) uint16_t outMTU;
@property (nonatomic, copy, nullable) void (^packetHandler)(NSData *packet);
@property (nonatomic, copy, nullable) void (^closedHandler)(void);

- (instancetype)initWithFD:(int)fd outMTU:(uint16_t)outMTU;
- (NSString *)describeType;
// Non-blocking send: returns NO with errno EAGAIN when the buffer is full
- (BOOL)send:(NSData *)data;
- (void)close;

@end

NS_ASSUME_NONNULL_END
