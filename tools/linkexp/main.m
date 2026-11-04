// linkexp: experiments on how bluetoothd and its stack bring a classic link up.
//
// Question (2026-11-03, GitHub issue #2 log of 2026-10-21): when L2CAP connection requests are still pending in the stack as
// the ACL is released, the stack pages the device again by itself ("Allocating ACL connection ... at state:1" in the same
// millisecond as "Releasing ACL connection"), and on that link bluetoothd ran no SDP and no profile connection round of its own.
// Can this be triggered on purpose?
//
//   linkexp state ADDR
//   linkexp connect ADDR             ConnectPeer (hand the headphones back to macOS)
//   linkexp drop ADDR                CancelPeerConnection with Force
//   linkexp repage ADDR [options]    with the link up: send PSM requests and force a disconnect, see what comes back
//     --lead MS      >= 0: first request MS before the forced disconnect; < 0: disconnect first, first request -MS after it (default 0)
//     --count N      number of requests, one per session (default 6)
//     --interval MS  gap between requests (default 20)
//     --psm P        PSM to request (default 25, AVDTP)
//     --hold S       seconds to watch after the disconnect (default 12)
//     --giveback     at the end close our channels, drop the link and ConnectPeer so macOS takes the headphones again
//     --avrcp        once signaling is open, also grab the AVRCP channel (PSM 0x17), as the app does
//     --hfp CH       once signaling is open, also grab the HFP RFCOMM channel CH
//     --soft         cancel without kCBCancelConnectOptionForce
//     --reply        answer the headphones' AVDTP DISCOVER with one source endpoint (as the app does)
//   linkexp cold ADDR [options]      with no link: ConnectPeer, and as soon as the link is up apply the same requests and
//                                    forced disconnect as repage (--lead counts from the link coming up)

#import <Foundation/Foundation.h>
#import "ClassicXPC.h"
#include <time.h>
#include <xpc/xpc.h>

static uint64_t gStart;

// ClassicSession's raw sender (declared here only for the experiment)
@interface ClassicSession (Raw)
- (void)send:(int64_t)messageId args:(nullable xpc_object_t)args;
@end

// CancelPeerConnection (message 46) without kCBCancelConnectOptionForce
static void SoftCancel(ClassicSession *session, NSUUID *device) {
    uuid_t bytes;
    [device getUUIDBytes:bytes];
    xpc_object_t args = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uuid(args, "kCBMsgArgDeviceUUID", bytes);
    xpc_dictionary_set_value(args, "kCBMsgArgOptions", xpc_dictionary_create(NULL, NULL, 0));
    [session send:46 args:args];
}

static double Ms(void) {
    return (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - gStart) / 1e6;
}

static void Log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    printf("[%8.1f] %s\n", Ms(), text.UTF8String);
    fflush(stdout);
}

static NSString *Hex(NSData *data) {
    NSMutableString *text = [NSMutableString string];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [text appendFormat:@"%02X ", bytes[i]];
    return text;
}

@interface Experiment : NSObject
@property (nonatomic, copy) NSString *address;
@property (nonatomic) double lead;
@property (nonatomic) NSUInteger count;
@property (nonatomic) double interval;
@property (nonatomic) uint16_t psm;
@property (nonatomic) double hold;
@property (nonatomic) BOOL giveback;
@property (nonatomic) BOOL avrcp;
@property (nonatomic) uint8_t hfp;
@property (nonatomic) BOOL reply;
@property (nonatomic) BOOL soft;
@end

@implementation Experiment {
    ClassicSession *_control;
    NSMutableArray<ClassicSession *> *_sessions;
    NSUUID *_uuid;
    NSUInteger _sent;
    NSMutableArray<L2CAPSocket *> *_sockets;
    NSMutableArray<ClassicSession *> *_openSessions;
    int64_t _lastState;
    dispatch_source_t _poll;
    BOOL _discoverDone;
    BOOL _extrasStarted;
    ClassicSession *_avrcpSession;
    ClassicSession *_hfpSession;
    L2CAPSocket *_avrcpSocket;
    L2CAPSocket *_hfpSocket;
    BOOL _cold;
    dispatch_source_t _coldPoll;
}

- (void)setUpThen:(dispatch_block_t)block {
    _control = [[ClassicSession alloc] initWithLabel:@"control"];
    _sessions = [NSMutableArray array];
    _sockets = [NSMutableArray array];
    _openSessions = [NSMutableArray array];
    for (NSUInteger i = 0; i < MAX(_count, 1); i++) {
        [_sessions addObject:[[ClassicSession alloc] initWithLabel:[NSString stringWithFormat:@"s%lu", (unsigned long)i + 1]]];
    }
    _avrcpSession = [[ClassicSession alloc] initWithLabel:@"avrcp"];
    _hfpSession = [[ClassicSession alloc] initWithLabel:@"hfp"];
    __block NSUInteger pending = _sessions.count + 3;
    dispatch_block_t one = ^{
        if (--pending == 0) block();
    };
    [_control whenReady:one];
    [_avrcpSession whenReady:one];
    [_hfpSession whenReady:one];
    for (ClassicSession *session in _sessions) [session whenReady:one];
}

- (void)watchConnections:(ClassicSession *)session {
    __weak typeof(self) weakSelf = self;
    session.peerConnectedHandler = ^(NSUUID *device) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && session == strongSelf->_control && [device isEqual:strongSelf->_uuid]) Log(@"%@: device-connected event", session.label);
    };
    session.channelClosedHandler = ^(uint16_t psm, int result) {
        Log(@"%@: channel PSM 0x%02X closed (result %d)", session.label, psm, result);
    };
}

- (void)startPolling {
    _lastState = -2;
    _poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_poll, DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_poll, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        int64_t state = [strongSelf->_control linkStateForAddress:strongSelf->_address];
        if (state != strongSelf->_lastState) {
            Log(@"link state %lld", state);
            strongSelf->_lastState = state;
        }
    });
    dispatch_resume(_poll);
}

- (void)sendRequest {
    if (_sent >= _sessions.count) return;
    ClassicSession *session = _sessions[_sent++];
    Log(@"%@: request PSM 0x%02X", session.label, _psm);
    __weak typeof(self) weakSelf = self;
    [session openChannel:_uuid psm:_psm handler:^(int result, uint16_t cid, uint16_t outMTU, int fd) {
        [weakSelf session:session opened:result cid:cid mtu:outMTU fd:fd];
    }];
}

- (void)session:(ClassicSession *)session opened:(int)result cid:(uint16_t)cid mtu:(uint16_t)mtu fd:(int)fd {
    if (result != 0) {
        Log(@"%@: result %d", session.label, result);
        return;
    }
    L2CAPSocket *socket = [[L2CAPSocket alloc] initWithFD:fd outMTU:mtu];
    Log(@"%@: OPEN, CID 0x%04X, outgoing MTU %u, %@", session.label, cid, mtu, socket.describeType);
    [_sockets addObject:socket];
    [_openSessions addObject:session];
    __weak L2CAPSocket *weakSocket = socket;
    BOOL reply = _reply;
    socket.packetHandler = ^(NSData *packet) {
        Log(@"%@: ← %@", session.label, Hex(packet));
        const uint8_t *bytes = packet.bytes;
        // An AVDTP command (message type 00) for DISCOVER (signal 01): answer with one audio source endpoint, SEID 1 not in use
        if (reply && packet.length >= 2 && (bytes[0] & 0x03) == 0x00 && (bytes[1] & 0x3F) == 0x01) {
            uint8_t answer[] = {(uint8_t)((bytes[0] & 0xF0) | 0x02), 0x01, 0x04, 0x00};
            Log(@"%@: → DISCOVER accept %@", session.label, Hex([NSData dataWithBytes:answer length:sizeof(answer)]));
            [weakSocket send:[NSData dataWithBytes:answer length:sizeof(answer)]];
        }
    };
    socket.closedHandler = ^{
        Log(@"%@: socket closed by the other side", session.label);
    };
    if (_psm == 0x19 && !_discoverDone) {
        _discoverDone = YES;
        uint8_t discover[] = {0x00, 0x01};
        Log(@"%@: → DISCOVER 00 01", session.label);
        [socket send:[NSData dataWithBytes:discover length:sizeof(discover)]];
        [self startExtras];
    }
}

- (void)startExtras {
    if (_extrasStarted) return;
    _extrasStarted = YES;
    if (_avrcp) {
        Log(@"avrcp: request PSM 0x17");
        [_avrcpSession openChannel:_uuid psm:0x17 handler:^(int result, uint16_t cid, uint16_t mtu, int fd) {
            if (result != 0) {
                Log(@"avrcp: result %d", result);
                return;
            }
            self->_avrcpSocket = [[L2CAPSocket alloc] initWithFD:fd outMTU:mtu];
            self->_avrcpSocket.packetHandler = ^(NSData *packet) { Log(@"avrcp: ← %@", Hex(packet)); };
            self->_avrcpSocket.closedHandler = ^{ Log(@"avrcp: socket closed by the other side"); };
            Log(@"avrcp: OPEN, CID 0x%04X", cid);
        }];
    }
    if (_hfp) {
        Log(@"hfp: request RFCOMM %u", _hfp);
        [_hfpSession openRFCOMM:_uuid channel:_hfp handler:^(int result, uint16_t mtu, uint16_t service16, int fd) {
            if (result != 0) {
                Log(@"hfp: result %d", result);
                return;
            }
            self->_hfpSocket = [[L2CAPSocket alloc] initWithFD:fd outMTU:mtu];
            self->_hfpSocket.packetHandler = ^(NSData *packet) {
                NSString *text = [[NSString alloc] initWithData:packet encoding:NSASCIIStringEncoding];
                Log(@"hfp: ← %@", [text stringByReplacingOccurrencesOfString:@"\r" withString:@" "]);
            };
            self->_hfpSocket.closedHandler = ^{ Log(@"hfp: socket closed by the other side"); };
            Log(@"hfp: OPEN, MTU %u", mtu);
        }];
    }
}

- (void)runRepage {
    _uuid = [_control lookupAddress:_address];
    if (!_uuid) {
        Log(@"device not found");
        exit(1);
    }
    for (ClassicSession *session in _sessions) [self watchConnections:session];
    [self watchConnections:_control];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    gStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    Log(@"t0 = %@, device %@, lead %.0f ms, %lu requests every %.0f ms, PSM 0x%02X", [formatter stringFromDate:[NSDate date]], _uuid.UUIDString,
        _lead, (unsigned long)_count, _interval, _psm);
    int64_t state = [_control linkStateForAddress:_address];
    Log(@"link state at start %lld", state);
    if (_cold) {
        if (state != 0) {
            Log(@"the link is up, cold needs it down");
            exit(1);
        }
        [self startPolling];
        Log(@"control: ConnectPeer");
        [_control connectDevice:_uuid];
        // Poll every 5 ms for the link to come up, then run the same sequence as repage
        _coldPoll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_coldPoll, DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC, NSEC_PER_MSEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_coldPoll, ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || [strongSelf->_control linkStateForAddress:strongSelf->_address] != 2) return;
            dispatch_source_cancel(strongSelf->_coldPoll);
            Log(@"link is up, starting the sequence");
            [strongSelf runSequence];
        });
        dispatch_resume(_coldPoll);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (self->_sent == 0) {
                Log(@"link did not come up within 20 s");
                exit(1);
            }
        });
        return;
    }
    if (state != 2) {
        Log(@"the link is not up, nothing to do");
        exit(1);
    }
    [self startPolling];
    [self runSequence];
}

- (void)runSequence {
    double firstRequest = _lead >= 0 ? 0 : -_lead;
    double disconnect = _lead >= 0 ? _lead : 0;
    for (NSUInteger i = 0; i < _count; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((firstRequest + i * _interval) * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self sendRequest];
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(disconnect * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (self.soft) {
            Log(@"control: cancel connection (no Force)");
            SoftCancel(self->_control, self->_uuid);
        } else {
            Log(@"control: forced disconnect");
            [self->_control cancelConnection:self->_uuid];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((disconnect + _hold * 1000) * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self finish];
    });
}

- (void)finish {
    Log(@"done watching, %lu channel(s) open", (unsigned long)_sockets.count);
    if (_avrcpSocket) {
        [_avrcpSession closeChannel:_uuid psm:0x17];
        [_avrcpSocket close];
    }
    if (_hfpSocket) {
        [_hfpSession closeRFCOMM:_uuid channel:_hfp];
        [_hfpSocket close];
    }
    for (NSUInteger i = 0; i < _openSessions.count; i++) {
        [_openSessions[i] closeChannel:_uuid psm:_psm];
        [_sockets[i] close];
    }
    if (!_giveback) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self->_control linkStateForAddress:self->_address] == 2) {
            Log(@"control: dropping the link");
            [self->_control cancelConnection:self->_uuid];
        }
        [self waitForLinkDownThenConnect:0];
    });
}

- (void)waitForLinkDownThenConnect:(int)tries {
    if ([_control linkStateForAddress:_address] == 2 && tries < 50) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self waitForLinkDownThenConnect:tries + 1];
        });
        return;
    }
    Log(@"control: ConnectPeer (give the headphones back to macOS)");
    [_control connectDevice:_uuid];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
}

@end

static double OptionValue(NSArray<NSString *> *arguments, NSString *name, double fallback) {
    NSUInteger index = [arguments indexOfObject:name];
    return index != NSNotFound && index + 1 < arguments.count ? arguments[index + 1].doubleValue : fallback;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        gStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        NSMutableArray<NSString *> *arguments = [NSMutableArray array];
        for (int i = 0; i < argc; i++) [arguments addObject:@(argv[i])];
        if (arguments.count < 3) {
            fprintf(stderr, "usage: linkexp state|connect|drop|repage ADDR [options]\n");
            return 2;
        }
        NSString *command = arguments[1];
        Experiment *experiment = [[Experiment alloc] init];
        experiment.address = [arguments[2] stringByReplacingOccurrencesOfString:@"-" withString:@":"];
        experiment.lead = OptionValue(arguments, @"--lead", 0);
        experiment.count = (NSUInteger)OptionValue(arguments, @"--count", 6);
        experiment.interval = OptionValue(arguments, @"--interval", 20);
        experiment.psm = (uint16_t)OptionValue(arguments, @"--psm", 0x19);
        experiment.hold = OptionValue(arguments, @"--hold", 12);
        experiment.giveback = [arguments containsObject:@"--giveback"];
        experiment.avrcp = [arguments containsObject:@"--avrcp"];
        experiment.hfp = (uint8_t)OptionValue(arguments, @"--hfp", 0);
        experiment.reply = [arguments containsObject:@"--reply"];
        experiment.soft = [arguments containsObject:@"--soft"];
        BOOL cold = [command isEqualToString:@"cold"];
        [experiment setValue:@(cold) forKey:@"_cold"];
        if (![command isEqualToString:@"repage"] && !cold) experiment.count = [command isEqualToString:@"optprobe"] ? 2 : 0;
        [experiment setUpThen:^{
            ClassicSession *control = [experiment valueForKey:@"_control"];
            NSUUID *uuid = [control lookupAddress:experiment.address];
            if ([command isEqualToString:@"state"]) {
                Log(@"device %@, link state %lld", uuid.UUIDString, [control linkStateForAddress:experiment.address]);
                if ([arguments containsObject:@"--dump"]) {
                    xpc_object_t record = [control performSelector:@selector(deviceRecordForAddress:) withObject:experiment.address];
                    char *description = record ? xpc_copy_description(record) : NULL;
                    if (description) printf("%s\n", description);
                    free(description);
                }
                exit(0);
            } else if ([command isEqualToString:@"connect"]) {
                Log(@"ConnectPeer");
                [control connectDevice:uuid];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
            } else if ([command isEqualToString:@"drop"]) {
                Log(@"forced disconnect");
                [control cancelConnection:uuid];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
            } else if ([command isEqualToString:@"optprobe"]) {
                // Open PSM 25 with the L2CAP options placed differently; bluetoothd logs what it parsed ("trying to connect ...
                // inMTU:... priority:...") even when there is no link and it refuses at once
                uuid_t bytes;
                [uuid getUUIDBytes:bytes];
                NSArray<NSArray *> *variants = @[
                    @[@"options/int", @1001, @3, @NO],
                    @[@"top-level/int", @1002, @4, @YES],
                ];
                NSArray<ClassicSession *> *sessions = [experiment valueForKey:@"_sessions"];
                for (NSUInteger i = 0; i < variants.count && i < sessions.count; i++) {
                    NSArray *v = variants[i];
                    xpc_object_t args = xpc_dictionary_create(NULL, NULL, 0);
                    xpc_dictionary_set_uuid(args, "kCBMsgArgDeviceUUID", bytes);
                    xpc_dictionary_set_int64(args, "kCBMsgArgPSM", 0x19);
                    xpc_object_t options = xpc_dictionary_create(NULL, NULL, 0);
                    xpc_object_t target = [v[3] boolValue] ? args : options;
                    xpc_dictionary_set_int64(target, "kCBL2CAPChannelInMTU", [v[1] longLongValue]);
                    xpc_dictionary_set_int64(target, "kCBL2CAPChannelPriority", [v[2] longLongValue]);
                    xpc_dictionary_set_value(args, "kCBMsgArgOptions", options);
                    Log(@"%@: inMTU %@ priority %@", v[0], v[1], v[2]);
                    [sessions[i] send:29 args:args];
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
            } else if ([command isEqualToString:@"repage"] || [command isEqualToString:@"cold"]) {
                [experiment runRepage];
            } else {
                fprintf(stderr, "unknown command %s\n", command.UTF8String);
                exit(2);
            }
        }];
        dispatch_main();
    }
    return 0;
}
