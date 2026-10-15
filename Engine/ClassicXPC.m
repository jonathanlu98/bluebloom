#import "ClassicXPC.h"
#include <xpc/xpc.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>

// The key names, message numbers and values below were all recorded by observation (tools/xpctrace.c, IOBluetooth → com.apple.server.bluetooth.classic.xpc)
static const char *const kServiceName = "com.apple.server.bluetooth.classic.xpc";
static const char *const kMsgId = "kCBMsgId";
static const char *const kMsgArgs = "kCBMsgArgs";
enum {
    kMsgCheckIn = 1,
    kMsgStateChanged = 6,
    kMsgAfterCheckIn = 10,
    kMsgRetrievePairedDevices = 12,
    kMsgChannelConnected = 27,
    kMsgChannelDisconnected = 28,
    kMsgOpenChannel = 29,
    kMsgCloseChannel = 30,
    kMsgRetrievePeerWithAddress = 44,
    kMsgConnectPeer = 45,
    kMsgCancelPeerConnection = 46,
    kMsgPeerConnected = 51,
    kMsgOpenRFCOMM = 59,
    kMsgCloseRFCOMM = 60,
    kMsgRFCOMMOpened = 62,
    kMsgRFCOMMClosed = 63,
};
// Check-in arguments copied from IOBluetooth: version 20161219, type 3, option kCBMsgArgIsPrivilegedDaemon=1
static const int64_t kCheckInVersion = 20161219;
static const int64_t kCheckInType = 3;
// Connect options copied from IOBluetooth's kCBOptionServicesKey = [4096]
static const int64_t kConnectServices = 4096;
static const int64_t kStatePoweredOn = 5;

@implementation ClassicSession {
    xpc_connection_t _connection;
    NSMutableDictionary<NSNumber *, ChannelOpenHandler> *_openHandlers;
    NSMutableDictionary<NSNumber *, RFCOMMOpenHandler> *_rfcommHandlers;
    BOOL _ready;
    NSMutableArray<dispatch_block_t> *_readyBlocks;
}

- (instancetype)initWithLabel:(NSString *)label {
    if ((self = [super init])) {
        _label = [label copy];
        _openHandlers = [NSMutableDictionary dictionary];
        _rfcommHandlers = [NSMutableDictionary dictionary];
        _connection = xpc_connection_create_mach_service(kServiceName, dispatch_get_main_queue(), 0);
        __weak typeof(self) weakSelf = self;
        xpc_connection_set_event_handler(_connection, ^(xpc_object_t event) { [weakSelf handleEvent:event]; });
        xpc_connection_resume(_connection);

        xpc_object_t options = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_int64(options, "kCBMsgArgIsPrivilegedDaemon", 1);
        xpc_object_t args = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_int64(args, "kCBMsgArgVersion", kCheckInVersion);
        xpc_dictionary_set_value(args, "kCBMsgArgOptions", options);
        xpc_dictionary_set_int64(args, "kCBMsgArgType", kCheckInType);
        xpc_dictionary_set_string(args, "kCBMsgArgName", (NSBundle.mainBundle.bundleIdentifier ?: @"bluebloom").UTF8String);
        [self send:kMsgCheckIn args:args];
        // Copy the two steps IOBluetooth takes after check-in: message 10 (empty arguments) and a synchronous message 12; only then does bluetoothd push state 6,
        // and looking up a device by address before that returns kCBMsgArgResult=12 (observed)
        [self send:kMsgAfterCheckIn args:xpc_dictionary_create(NULL, NULL, 0)];
        xpc_object_t query = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_int64(query, kMsgId, kMsgRetrievePairedDevices);
        xpc_connection_send_message_with_reply(_connection, query, dispatch_get_main_queue(), ^(xpc_object_t reply) {});
    }
    return self;
}

- (void)whenReady:(dispatch_block_t)block {
    if (_ready) {
        block();
        return;
    }
    if (!_readyBlocks) _readyBlocks = [NSMutableArray array];
    [_readyBlocks addObject:[block copy]];
}

- (void)send:(int64_t)messageId args:(nullable xpc_object_t)args {
    // After invalidate the connection is nil, and sending a message on a nil connection makes XPC terminate the process (observed 2026-10-13 20:15:46: a delayed task that fired after teardown tried to close a channel)
    if (!_connection) return;
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(message, kMsgId, messageId);
    if (args) xpc_dictionary_set_value(message, kMsgArgs, args);
    xpc_connection_send_message(_connection, message);
}

static xpc_object_t DeviceArgs(NSUUID *device) {
    uuid_t bytes;
    [device getUUIDBytes:bytes];
    xpc_object_t args = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uuid(args, "kCBMsgArgDeviceUUID", bytes);
    return args;
}

- (NSUUID *)lookupAddress:(NSString *)address {
    xpc_object_t args = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(args, "kCBMsgArgAddressString", address.lowercaseString.UTF8String);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(message, kMsgId, kMsgRetrievePeerWithAddress);
    xpc_dictionary_set_value(message, kMsgArgs, args);
    if (!_connection) return nil;
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(_connection, message);
    xpc_object_t devices = xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_value(reply, "kCBMsgArgDevices") : NULL;
    if (!devices || xpc_get_type(devices) != XPC_TYPE_DICTIONARY) {
        char *description = xpc_copy_description(reply);
        fprintf(stderr, "Looking up device by address failed, reply: %s\n", description);
        free(description);
        return nil;
    }
    const uint8_t *bytes = xpc_dictionary_get_uuid(devices, "kCBMsgArgDeviceUUID");
    return bytes ? [[NSUUID alloc] initWithUUIDBytes:bytes] : nil;
}

- (void)connectDevice:(NSUUID *)device {
    xpc_object_t services = xpc_array_create(NULL, 0);
    xpc_array_set_int64(services, XPC_ARRAY_APPEND, kConnectServices);
    xpc_object_t options = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(options, "kCBOptionServicesKey", services);
    xpc_object_t args = DeviceArgs(device);
    xpc_dictionary_set_value(args, "kCBMsgArgOptions", options);
    [self send:kMsgConnectPeer args:args];
}

- (void)cancelConnection:(NSUUID *)device {
    // IOBluetooth's closeConnection passes kCBCancelConnectOptionForce=1, which forcibly disconnects all services of the device (observed)
    xpc_object_t options = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(options, "kCBCancelConnectOptionForce", 1);
    xpc_object_t args = DeviceArgs(device);
    xpc_dictionary_set_value(args, "kCBMsgArgOptions", options);
    [self send:kMsgCancelPeerConnection args:args];
}

- (BOOL)openInFlight {
    return _openHandlers.count > 0;
}

- (void)openChannel:(NSUUID *)device psm:(uint16_t)psm handler:(ChannelOpenHandler)handler {
    [self openChannel:device psm:psm priority:0 handler:handler];
}

- (void)openChannel:(NSUUID *)device psm:(uint16_t)psm priority:(int64_t)priority handler:(ChannelOpenHandler)handler {
    _openHandlers[@(psm)] = [handler copy];
    xpc_object_t args = DeviceArgs(device);
    xpc_dictionary_set_int64(args, "kCBMsgArgPSM", psm);
    xpc_object_t options = xpc_dictionary_create(NULL, NULL, 0);
    if (priority) xpc_dictionary_set_int64(options, "kCBL2CAPChannelPriority", priority);
    xpc_dictionary_set_value(args, "kCBMsgArgOptions", options);
    [self send:kMsgOpenChannel args:args];
}

- (void)closeChannel:(NSUUID *)device psm:(uint16_t)psm {
    xpc_object_t args = DeviceArgs(device);
    xpc_dictionary_set_int64(args, "kCBMsgArgPSM", psm);
    [self send:kMsgCloseChannel args:args];
}

- (BOOL)rfcommInFlight {
    return _rfcommHandlers.count > 0;
}

// Message format observed from IOBluetooth's openRFCOMMChannelAsync (tools/rfcommprobe.m + xpctrace, 2026-10-12):
// 59 {DeviceUUID, RFCOMMChannelID, Options={}} → event 62 {Result, RFCOMMChannelID, MTU, Socket, IsIncoming, ServiceUUID};
// Result=913 when macOS already holds the channel
- (void)openRFCOMM:(NSUUID *)device channel:(uint8_t)channel handler:(RFCOMMOpenHandler)handler {
    _rfcommHandlers[@(channel)] = [handler copy];
    xpc_object_t args = DeviceArgs(device);
    xpc_dictionary_set_int64(args, "kCBMsgArgRFCOMMChannelID", channel);
    xpc_dictionary_set_value(args, "kCBMsgArgOptions", xpc_dictionary_create(NULL, NULL, 0));
    [self send:kMsgOpenRFCOMM args:args];
}

- (void)closeRFCOMM:(NSUUID *)device channel:(uint8_t)channel {
    xpc_object_t args = DeviceArgs(device);
    xpc_dictionary_set_int64(args, "kCBMsgArgRFCOMMChannelID", channel);
    [self send:kMsgCloseRFCOMM args:args];
}

- (void)handleEvent:(xpc_object_t)event {
    if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
    int64_t messageId = xpc_dictionary_get_int64(event, kMsgId);
    xpc_object_t args = xpc_dictionary_get_value(event, kMsgArgs);
    switch (messageId) {
        case kMsgChannelConnected: {
            uint16_t psm = (uint16_t)xpc_dictionary_get_int64(args, "kCBMsgArgPSM");
            ChannelOpenHandler handler = _openHandlers[@(psm)];
            [_openHandlers removeObjectForKey:@(psm)];
            int result = (int)xpc_dictionary_get_int64(args, "kCBMsgArgResult");
            int fd = result == 0 ? xpc_dictionary_dup_fd(args, "kCBMsgArgSocket") : -1;
            if (handler) {
                handler(result, (uint16_t)xpc_dictionary_get_int64(args, "kCBMsgArgCID"),
                        (uint16_t)xpc_dictionary_get_int64(args, "kCBMsgArgOutMTU"), fd);
            } else if (fd >= 0) {
                close(fd);
            }
            break;
        }
        case kMsgRFCOMMOpened: {
            uint8_t channel = (uint8_t)xpc_dictionary_get_int64(args, "kCBMsgArgRFCOMMChannelID");
            RFCOMMOpenHandler handler = _rfcommHandlers[@(channel)];
            [_rfcommHandlers removeObjectForKey:@(channel)];
            int result = (int)xpc_dictionary_get_int64(args, "kCBMsgArgResult");
            int fd = result == 0 ? xpc_dictionary_dup_fd(args, "kCBMsgArgSocket") : -1;
            size_t serviceLength = 0;
            const uint8_t *service = xpc_dictionary_get_data(args, "kCBMsgArgServiceUUID", &serviceLength);
            uint16_t service16 = service && serviceLength == 2 ? (uint16_t)(service[0] << 8 | service[1]) : 0;
            if (handler) {
                handler(result, (uint16_t)xpc_dictionary_get_int64(args, "kCBMsgArgMTU"), service16, fd);
            } else if (fd >= 0) {
                close(fd);
            }
            break;
        }
        case kMsgRFCOMMClosed:
            if (_rfcommClosedHandler) {
                _rfcommClosedHandler((uint8_t)xpc_dictionary_get_int64(args, "kCBMsgArgRFCOMMChannelID"),
                                     (int)xpc_dictionary_get_int64(args, "kCBMsgArgResult"));
            }
            break;
        case kMsgChannelDisconnected:
            if (_channelClosedHandler) {
                _channelClosedHandler((uint16_t)xpc_dictionary_get_int64(args, "kCBMsgArgPSM"),
                                      (int)xpc_dictionary_get_int64(args, "kCBMsgArgResult"));
            }
            break;
        case kMsgPeerConnected:
            if (_peerConnectedHandler) {
                const uint8_t *bytes = args ? xpc_dictionary_get_uuid(args, "kCBMsgArgDeviceUUID") : NULL;
                _peerConnectedHandler(bytes ? [[NSUUID alloc] initWithUUIDBytes:bytes] : nil);
            }
            break;
        case kMsgStateChanged:
            // Observed: kCBMsgArgState=5 when Bluetooth is powered on
            if (!_ready && xpc_dictionary_get_int64(args, "kCBMsgArgState") == kStatePoweredOn) {
                _ready = YES;
                NSArray<dispatch_block_t> *blocks = _readyBlocks;
                _readyBlocks = nil;
                for (dispatch_block_t block in blocks) block();
            }
            break;
        default:
            break;
    }
}

- (void)invalidate {
    if (_connection) {
        xpc_connection_cancel(_connection);
        _connection = nil;
    }
}

// Also disconnect from bluetoothd when the session object is released without a normal teardown (e.g. the controller was replaced)
- (void)dealloc {
    [self invalidate];
}

@end

@implementation L2CAPSocket {
    dispatch_source_t _readSource;
}

- (instancetype)initWithFD:(int)fd outMTU:(uint16_t)outMTU {
    if ((self = [super init])) {
        _fd = fd;
        _outMTU = outMTU;
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        int noSigPipe = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_readSource, ^{ [weakSelf readAvailable]; });
        dispatch_resume(_readSource);
    }
    return self;
}

- (NSString *)describeType {
    int type = 0;
    socklen_t length = sizeof(type);
    getsockopt(_fd, SOL_SOCKET, SO_TYPE, &type, &length);
    switch (type) {
        case SOCK_STREAM: return @"SOCK_STREAM";
        case SOCK_DGRAM: return @"SOCK_DGRAM";
        case SOCK_SEQPACKET: return @"SOCK_SEQPACKET";
        default: return [NSString stringWithFormat:@"type %d", type];
    }
}

- (void)readAvailable {
    uint8_t buffer[4096];
    for (;;) {
        ssize_t count = recv(_fd, buffer, sizeof(buffer), 0);
        if (count > 0) {
            if (_packetHandler) _packetHandler([NSData dataWithBytes:buffer length:(NSUInteger)count]);
            continue;
        }
        if (count == 0 || (errno != EAGAIN && errno != EINTR)) {
            // Call back before closing the fd: the callback first synchronously stops streaming on the other thread, so it cannot write to the wrong place after the fd number is reused
            L2CAPSocket *strongSelf = self;
            if (strongSelf->_closedHandler) strongSelf->_closedHandler();
            [strongSelf close];
        }
        return;
    }
}

- (void)dealloc {
    [self close];
}

- (BOOL)send:(NSData *)data {
    if (_fd < 0) return NO;
    ssize_t count = send(_fd, data.bytes, data.length, 0);
    return count == (ssize_t)data.length;
}

- (void)close {
    if (_readSource) {
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    }
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

@end
