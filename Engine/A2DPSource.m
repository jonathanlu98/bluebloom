#import "A2DPSource.h"
#import <AVFoundation/AVFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#import "BBLog.h"
#import "A2DPProtocol.h"
#import "ClassicXPC.h"
#import "MediaStreamer.h"
#import "AvrcpController.h"
#import "HandsfreeGateway.h"
#import "HeadsetAudioGuard.h"
#import "SystemAudio.h"
#import "TestSources.h"
#include "VirtualDeviceProtocol.h"

static const uint8_t kLocalSeid = 1;
static const double kRequestTimeout = 5;
// Grabbing the signaling channel: each session has at most one request in flight (overlapping requests on the same
// session get 1803 "Already connected" from bluetoothd); sessions take turns, one request every 40ms, until we win or time out
static const NSUInteger kRaceSessions = 6;
static const double kRaceInterval = 0.04;
static const double kRoundTimeout = 6;
static const NSUInteger kRaceRounds = 4;
static const double kLinkWaitTimeout = 120;
// For one connection request bluetoothd pages only 3 times (about 5.4 s each, then logs "No pending connection to process";
// observed 2026-10-15) and then stops looking for the headphones. While waiting for the link, request again at this interval;
// the ten-plus seconds without paging in between are when the Mac can receive the headphones' own reconnection
static const double kRepageSeconds = 30;
// When grabbing the HFP channel, this many consecutive 913s (observed: macOS already holds that RFCOMM channel) means this
// round is lost; stop retrying
static const NSUInteger kHandsfreeBusyLimit = 5;
static const int kRFCOMMChannelBusy = 913;
// AVCTP control channel (AVRCP): BlueZ lib/sdp.h AVCTP_PSM
static const uint16_t kAVCTPPSM = 0x17;
// After the media channel opens, this many consecutive refusals (454) while grabbing the AVRCP channel means this connection
// will not get it (the headphones may already have AVRCP with macOS; Bathys returns 454 to everyone once the media channel is
// open, see kAvrcpSetupWindow)
static const NSUInteger kAvrcpBusyLimit = 5;
// When the AVRCP channel cannot be had, retry at this interval: macOS may let go later, and only after grabbing it back can
// volume be handed to the headphone amp (with software volume the headphone amp stays at the last synced value, e.g. 48/127,
// and the Mac volume is attenuated again in software, so it sounds quiet)
static const double kAvrcpRetrySeconds = 10;
// 0.1–0.7 s after the link comes up, bluetoothd connects A2DP, AVRCP and HFP once each ("handling connection that was pending",
// only once per link setup); the headphones often take a few hundred ms, sometimes nearly 1 s, to answer. If its AVDTP connection
// request lands after our stream is configured, the headphones misbehave: if it is still pending when OPEN is accepted, it is
// taken as this stream's media channel and our own media channel gets 454 (2026-10-15 05:25:56, 05:29:06); if it arrives after
// configuration but before OPEN, the headphones ABORT the stream about 0.6 s later (05:59:36). If it arrives when there is only
// signaling and no configuration yet, the headphones just return 454. So configure only this long after the link comes up
static const double kConfigureAfterLinkSeconds = 1.8;
// The AVRCP channel must connect before the media channel: in the 2026-10-15 bluetoothd log every AVRCP channel Bathys accepted
// came before the media channel opened; after the media channel opened, both macOS's and our requests got 454 for the whole
// connection (retrying every 10 s, for minutes). Keep grabbing the AVRCP channel while waiting to configure
static const double kAvrcpSetupWindow = kConfigureAfterLinkSeconds;
// SUSPEND after the capture source has been silent this long, freeing the air interface; START again when there is sound
// (the headphones buffer about 220ms; the first bit is covered by the capture ring buffer)
static const double kIdleSuspendSeconds = 10;
NSString *const VirtualDeviceUID = @kBBDeviceUID;
// Maximum number of close-and-reopen attempts after the media channel is refused
static const NSUInteger kMediaRetries = 2;
// Number of retries when SET_CONFIGURATION is rejected because the endpoint is not idle (0x31)
static const NSUInteger kConfigureRetries = 3;
// Number of resends and interval when OPEN returns 0x31
static const NSUInteger kOpenRetries = 5;
static const double kOpenRetryInterval = 0.3;


static NSString *SignalName(uint8_t signal) {
    static NSString *const names[] = {
        @"?", @"DISCOVER", @"GET_CAPABILITIES", @"SET_CONFIGURATION", @"GET_CONFIGURATION",
        @"RECONFIGURE", @"OPEN", @"START", @"CLOSE", @"SUSPEND", @"ABORT", @"SECURITY_CONTROL",
        @"GET_ALL_CAPABILITIES", @"DELAY_REPORT",
    };
    return signal < sizeof(names) / sizeof(names[0]) ? names[signal] : [NSString stringWithFormat:@"0x%02X", signal];
}

static NSString *MessageTypeName(uint8_t type) {
    switch (type) {
        case kMsgCommand: return @"command";
        case kMsgGeneralReject: return @"general reject";
        case kMsgAccept: return @"accept";
        default: return @"reject";
    }
}

// The channel socket bluetoothd hands over is SOCK_STREAM (observed), so back-to-back signals may arrive in a single read;
// cut out the length of the first one from the signal format. Lengths follow the fixed format of each AVDTP signal (structs
// such as seid_req / delay_req / stream_rej / conf_rej in BlueZ avdtp.c); variable-length messages run to the end
static size_t AVDTPMessageLength(const uint8_t *bytes, size_t available) {
    if (available < 2 || ((bytes[0] >> 2) & 0x03) != kPktSingle) return available;
    uint8_t messageType = bytes[0] & 0x03;
    uint8_t signal = bytes[1] & 0x3F;
    size_t length = available;
    switch (messageType) {
        case kMsgCommand:
            if (signal == kSigDiscover) length = 2;
            else if (signal == kSigDelayReport) length = 5;
            else if (signal != kSigSetConfiguration && signal != kSigReconfigure && signal != kSigSecurityControl) length = 3;
            break;
        case kMsgAccept:
            if (signal != kSigDiscover && signal != kSigGetCapabilities && signal != kSigGetAllCapabilities &&
                signal != kSigGetConfiguration && signal != kSigSecurityControl) length = 2;
            break;
        case kMsgReject:
            length = (signal == kSigSetConfiguration || signal == kSigReconfigure || signal == kSigStart || signal == kSigSuspend) ? 4 : 3;
            break;
        case kMsgGeneralReject:
            length = 2;
            break;
    }
    return MIN(length, available);
}

typedef NS_ENUM(NSInteger, SourceState) {
    SourceStateIdle,
    SourceStateReconnecting,
    SourceStateConnecting,
    SourceStateRacing,
    SourceStateSignalReady,
    SourceStateConfigured,
    SourceStateOpeningMedia,
    SourceStateMediaReady,
    SourceStateStreaming,
};

typedef void (^ReplyBlock)(uint8_t messageType, const uint8_t *payload, size_t length);

@interface SinkEndpoint : NSObject
@property (nonatomic) uint8_t seid;
@property (nonatomic) BOOL inUse;
@property (nonatomic) uint8_t mediaType;
@property (nonatomic) uint8_t sepType;
@property (nonatomic, copy, nullable) NSData *codecElement;      // Contents of the media codec service category (from the media type byte)
@property (nonatomic, strong, nullable) A2DPCodec *codec;        // Codec implemented on our side; nil if not implemented
@property (nonatomic) BOOL delayReporting;
@property (nonatomic) BOOL busy;                                 // Configuring it returned 0x31/0x13 during this connection
@end

@implementation SinkEndpoint
@end

// Result of chooseCodec
@interface CodecChoice : NSObject
@property (nonatomic, strong, nullable) SinkEndpoint *endpoint;
@property (nonatomic, strong, nullable) CodecConfiguration *configuration;
@property (nonatomic, copy, nullable) CodecID fallbackCodec;
@property (nonatomic) CodecFallbackReason fallbackReason;
@end

@implementation CodecChoice
@end

@interface A2DPSource () <IOBluetoothDevicePairDelegate>
@end


@implementation A2DPSource {
    IOBluetoothDevice *_device;
    SourceMode _mode;
    double _requestedRate;
    NSString *_filePath;
    double _seconds;
    BOOL _useSystemAudio;
    SystemAudioSource *_systemAudio;
    HeadsetAudioGuard *_audioGuard;

    ClassicSession *_handsfreeSession;
    uint8_t _handsfreeChannel;
    HandsfreeGateway *_gateway;
    BOOL _handsfreeLost;
    NSUInteger _handsfreeAttempts;
    NSUInteger _handsfreeBusyStreak;
    uint64_t _handsfreeLookupTicks;

    ClassicSession *_avrcpSession;
    AvrcpController *_avrcp;
    BOOL _avrcpLost;
    uint64_t _avrcpLostTicks;  // When it was last confirmed to be held by macOS
    NSUInteger _avrcpAttempts;
    NSUInteger _avrcpBusyStreak;
    NSMutableDictionary<NSNumber *, NSNumber *> *_handsfreeRefusals;

    SourceState _state;
    BOOL _wasConnected;
    NSUUID *_uuid;
    IOBluetoothDevicePair *_pairing;

    NSMutableArray<ClassicSession *> *_raceSessions;
    ClassicSession *_mediaSession;
    ClassicSession *_signalSession;
    dispatch_source_t _raceTimer;
    NSUInteger _round;
    uint64_t _roundDeadline;
    uint64_t _roundStartTicks;
    uint64_t _linkTicks;            // When this round's link came up (or signaling was grabbed); 0 means not yet
    uint64_t _pageTicks;            // When bluetoothd was last asked to connect (page)
    BOOL _waitHintShown;
    NSUInteger _attempts;
    NSMutableDictionary<NSNumber *, NSNumber *> *_refusals;

    L2CAPSocket *_signal;
    L2CAPSocket *_media;
    NSMutableData *_signalBuffer;

    uint8_t _nextLabel;
    uint8_t _pendingLabel;
    uint8_t _pendingSignal;
    ReplyBlock _pendingReply;
    NSUInteger _pendingSequence;

    NSMutableData *_fragment;
    uint8_t _fragmentSignal;
    uint8_t _fragmentLabel;
    uint8_t _fragmentMessageType;

    NSMutableArray<SinkEndpoint *> *_endpoints;
    BOOL _useGetAllCapabilities;
    SinkEndpoint *_chosen;          // Currently configured endpoint
    A2DPCodec *_codec;
    NSMutableDictionary<CodecID, NSNumber *> *_failedCodecs;  // Codecs that failed in this session → CodecFallbackReason
    NSMutableSet<NSNumber *> *_unsettableRates;               // Virtual device sample rates tried but not settable (old driver)
    double _awaitingRate;           // Sample rate the virtual device was asked to switch to, waiting to take effect
    NSUInteger _rateRequests;
    BOOL _pendingReconfigure;
    BOOL _pendingStallRecovery;
    BOOL _handToSystem;

    MediaStreamer *_streamer;
    NSUInteger _mediaRetries;
    NSUInteger _configureRetries;
    NSUInteger _openRetries;
    dispatch_source_t _idleTimer;
    LinkStatus _linkStatus;
    int _batteryPercent;
    BOOL _idleSuspended;
    uint64_t _suspendedTicks;
    BOOL _commandInFlight;

    BOOL _stopping;
    BOOL _tornDown;
    int _exitCode;
}

- (instancetype)initWithDevice:(IOBluetoothDevice *)device mode:(SourceMode)mode rate:(double)rate file:(NSString *)file
                       seconds:(double)seconds systemAudio:(BOOL)systemAudio {
    if ((self = [super init])) {
        _device = device;
        _mode = mode;
        _requestedRate = rate;
        _filePath = [file copy];
        _seconds = seconds;
        _useSystemAudio = systemAudio;
        _raceSessions = [NSMutableArray array];
        _refusals = [NSMutableDictionary dictionary];
        _signalBuffer = [NSMutableData data];
        _endpoints = [NSMutableArray array];
        _failedCodecs = [NSMutableDictionary dictionary];
        _unsettableRates = [NSMutableSet set];
        _options = [CodecOptions new];
        _useGetAllCapabilities = YES;
        _batteryPercent = -1;
    }
    return self;
}

NSString *A2DPDeviceIdentity(IOBluetoothDevice *device) {
    NSMutableString *text = [NSMutableString stringWithFormat:@"class 0x%06X", (unsigned)device.classOfDevice];
    IOBluetoothSDPServiceRecord *record = [device getServiceRecordForUUID:[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassPnPInformation]];
    if (!record) {
        [text appendString:@", no Device ID record"];
        return text;
    }
    // Device ID profile attributes: 0x0201 vendor ID, 0x0202 product ID, 0x0203 version, 0x0205 vendor ID source (1 Bluetooth SIG, 2 USB-IF)
    NSNumber *(^value)(BluetoothSDPServiceAttributeID) = ^NSNumber *(BluetoothSDPServiceAttributeID attribute) {
        return [[record getAttributeDataElement:attribute] getNumberValue];
    };
    NSNumber *source = value(0x0205);
    NSString *sourceName = source.intValue == 1 ? @"Bluetooth SIG" : source.intValue == 2 ? @"USB-IF" : [NSString stringWithFormat:@"source %@", source ?: @"?"];
    [text appendFormat:@", vendor 0x%04X (%@), product 0x%04X, version 0x%04X", value(0x0201).unsignedIntValue, sourceName,
                       value(0x0202).unsignedIntValue, value(0x0203).unsignedIntValue];
    return text;
}

- (NSUUID *)deviceIdentifier {
    return _uuid;
}

- (void)reportStatus:(LinkStatus)status {
    _linkStatus = status;
    if (_statusHandler) _statusHandler(status, _configuration.sampleRate, _batteryPercent);
}

#pragma mark Connecting and grabbing the signaling channel

- (void)start {
    _wasConnected = _device.isConnected;
    BBLog(@"Target: %@ [%@], paired=%d, currently connected=%d", _device.name, _device.addressString, _device.isPaired, _wasConnected);
    BBLog(@"Headphones: %@", A2DPDeviceIdentity(_device));
    // Guard the default device first, then build the tap: the tap's aggregate device uses the default output at that moment
    // as its clock source, and that must not be the headphones' call device
    _audioGuard = [[HeadsetAudioGuard alloc] initWithAddress:_device.addressString];
    _audioGuard.logHandler = ^(NSString *message) { BBLog(@"%@", message); };
    [_audioGuard start];
    if (_useSystemAudio || _useVirtualDevice) {
        // Build the capture source first to get its sample rate, so codec selection can match it and avoid resampling
        NSString *error = nil;
        _systemAudio = _useVirtualDevice ? [[SystemAudioSource alloc] initWithDeviceUID:VirtualDeviceUID error:&error]
                                         : [[SystemAudioSource alloc] initWithError:&error];
        if (!_systemAudio) {
            [self stopWithReason:error exitCode:7];
            return;
        }
        BBLog(@"System audio source: %@", _systemAudio.formatDescription);
        [self watchSampleRate];
    }
    for (NSUInteger i = 0; i < kRaceSessions; i++) {
        [_raceSessions addObject:[[ClassicSession alloc] initWithLabel:[NSString stringWithFormat:@"session %lu", (unsigned long)i]]];
    }
    // bluetoothd allows only one channel per session per device, so the media channel uses its own session
    _mediaSession = [[ClassicSession alloc] initWithLabel:@"media session"];
    // The HFP channel number comes from the system's SDP cache; once we grab it macOS cannot connect HFP, so it does not
    // publish the headphones' call device
    _handsfreeChannel = [self handsfreeChannelFromSDP];
    _handsfreeRefusals = [NSMutableDictionary dictionary];
    _handsfreeSession = [[ClassicSession alloc] initWithLabel:@"hands-free session"];
    // About 2 s after connecting, the headphones connect AVRCP themselves (observed RecvConnectReq psm=23); connecting first
    // keeps macOS from getting the AVRCP channel
    _avrcpSession = [[ClassicSession alloc] initWithLabel:@"AVRCP session"];
    if (_handsfreeChannel) {
        BBLog(@"Headphones' HFP service is on RFCOMM channel %u, grabbing it while connecting", _handsfreeChannel);
    } else {
        // Observed: right after app launch IOBluetooth has not loaded the device's SDP cache yet and reads come back empty;
        // reading continues during the grab
        BBLog(@"Cannot read the headphones' HFP service channel yet, will keep reading while connecting");
    }
    __weak typeof(self) weakSelf = self;
    [_raceSessions[0] whenReady:^{ [weakSelf sessionsReady]; }];
}

- (void)sessionsReady {
    NSString *address = [_device.addressString stringByReplacingOccurrencesOfString:@"-" withString:@":"];
    _uuid = [_raceSessions[0] lookupAddress:address];
    BBLog(@"Direct to bluetoothd: %lu+1 sessions checked in, device UUID %@", (unsigned long)kRaceSessions, _uuid.UUIDString ?: @"(not found)");
    if (!_uuid) {
        [self stopWithReason:@"bluetoothd cannot find this device" exitCode:2];
        return;
    }
    if (!_device.isPaired) {
        [self pair];
        return;
    }
    [self connect];
}

- (void)connect {
    if (_wasConnected) BBLog(@"Note: the headphones are already connected to this Mac and macOS most likely holds A2DP; if the first round fails, will force a disconnect and reconnect");
    __weak typeof(self) weakSelf = self;
    _raceSessions[0].peerConnectedHandler = ^(NSUUID *device) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Also received when other headphones connect to the Mac; without a device UUID, treat it as the target (old behavior)
        if (device && ![device isEqual:strongSelf->_uuid]) return;
        [strongSelf linkReady:@"session 0 received device-connected event"];
    };
    _raceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_raceTimer, DISPATCH_TIME_NOW, (uint64_t)(kRaceInterval * NSEC_PER_SEC), NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_raceTimer, ^{ [weakSelf raceTick]; });
    dispatch_resume(_raceTimer);
    [self startRound];
}

// The only chance to grab is while macOS is setting up A2DP (just after the link comes up, or colliding with macOS opening
// the media channel); once the system's stream is up there is no way in (all 454), so each round is time-limited and on
// failure we force a disconnect, bring the link up again and retry
- (void)startRound {
    _round++;
    _state = SourceStateConnecting;
    // The round timer starts when the link comes up: if the headphones do not answer paging (observed often after a forced
    // disconnect), keep waiting for them to reconnect on their own; that does not count as failure
    _roundDeadline = 0;
    _roundStartTicks = mach_absolute_time();
    _linkTicks = 0;
    _waitHintShown = NO;
    BBLog(@"Round %lu/%lu: connecting and grabbing the signaling channel", (unsigned long)_round, (unsigned long)kRaceRounds);
    [self reportStatus:LinkStatusConnecting];
    [_raceSessions[0] connectDevice:_uuid];
    _pageTicks = _roundStartTicks;
}

- (void)restartRound:(NSString *)reason {
    if (_round >= kRaceRounds) {
        [self stopWithReason:[NSString stringWithFormat:@"No usable signaling channel in %lu rounds (last round: %@; %lu requests in total, refusals %@)",
                              (unsigned long)_round, reason, (unsigned long)_attempts, _refusals] exitCode:2];
        return;
    }
    BBLog(@"Round %lu failed (%@), forcing a disconnect and retrying", (unsigned long)_round, reason);
    _state = SourceStateReconnecting;
    [self resetHandsfree];
    [self resetAvrcp];
    [_raceSessions[0] cancelConnection:_uuid];
    [self startRoundAfterDisconnect:0];
}

- (void)startRoundAfterDisconnect:(int)checks {
    if (_stopping) return;
    if (_device.isConnected && checks < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self startRoundAfterDisconnect:checks + 1]; });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self->_stopping) [self startRound];
    });
}

- (void)linkReady:(NSString *)reason {
    if (_state != SourceStateConnecting) return;
    _state = SourceStateRacing;
    _linkTicks = mach_absolute_time();
    _roundDeadline = _linkTicks + BBSecondsToTicks(kRoundTimeout);
    BBLog(@"Link is up (%@)", reason);
}

- (uint8_t)handsfreeChannelFromSDP {
    IOBluetoothSDPUUID *handsfree = [IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassHandsFree];
    for (IOBluetoothSDPServiceRecord *record in _device.services) {
        BluetoothRFCOMMChannelID channel = 0;
        if ([record matchesUUIDArray:@[handsfree]] && [record getRFCOMMChannelID:&channel] == kIOReturnSuccess) return channel;
    }
    return 0;
}

// macOS connects HFP about 1 s after SDP completes (observed "Attempting to connect handsfree"); like the signaling grab,
// we start requesting without waiting for the link to come up.
// Between grabbing signaling and the media channel opening (configure, OPEN, open media channel): send no new HFP requests,
// so the headphones handle one thing at a time; the AVRCP channel is the exception and is still grabbed within
// kAvrcpSetupWindow (the headphones stop accepting it once the media channel is open; this is exactly when we are waiting to
// configure), and OPEN waits until its request has a result (openWhenQuiet).
// Observed (2026-10-13 20:47:21, WH-1000XM4): with the AVRCP channel just up and the HFP RFCOMM being set up, our media channel
// request got an L2CAP Command Reject (OI 445) from the headphones and the stream was dead; opening the media channel alone
// always succeeded
- (BOOL)settingUpStream {
    return _state == SourceStateSignalReady || _state == SourceStateConfigured || _state == SourceStateOpeningMedia;
}

- (void)handsfreeTick {
    if (!_handsfreeSession.ready || _handsfreeSession.rfcommInFlight || _gateway || _handsfreeLost || _stopping) return;
    if (_state == SourceStateIdle || _state == SourceStateReconnecting || [self settingUpStream]) return;
    if (!_handsfreeChannel) {
        // Re-read the SDP cache every 0.5 s (reads go over XPC; no need to read every 40ms cycle)
        uint64_t now = mach_absolute_time();
        if (now - _handsfreeLookupTicks < BBSecondsToTicks(0.5)) return;
        _handsfreeLookupTicks = now;
        _handsfreeChannel = [self handsfreeChannelFromSDP];
        if (!_handsfreeChannel) return;
        BBLog(@"Found the headphones' HFP service: RFCOMM channel %u, starting to grab it", _handsfreeChannel);
    }
    _handsfreeAttempts++;
    __weak typeof(self) weakSelf = self;
    [_handsfreeSession openRFCOMM:_uuid channel:_handsfreeChannel handler:^(int result, uint16_t mtu, uint16_t service16, int fd) {
        [weakSelf handsfreeOpened:result mtu:mtu service:service16 fd:fd];
    }];
}

- (void)handsfreeOpened:(int)result mtu:(uint16_t)mtu service:(uint16_t)service16 fd:(int)fd {
    if (result != 0) {
        _handsfreeRefusals[@(result)] = @(_handsfreeRefusals[@(result)].integerValue + 1);
        _handsfreeBusyStreak = result == kRFCOMMChannelBusy ? _handsfreeBusyStreak + 1 : 0;
        if (_handsfreeBusyStreak >= kHandsfreeBusyLimit && !_handsfreeLost) {
            _handsfreeLost = YES;
            BBLog(@"macOS took the HFP channel first (%lu consecutive %d): this round macOS may publish the headphones' call device; the default device guard covers it",
                (unsigned long)_handsfreeBusyStreak, kRFCOMMChannelBusy);
        }
        return;
    }
    if (_stopping || _state == SourceStateReconnecting || _gateway) {
        close(fd);
        [_handsfreeSession closeRFCOMM:_uuid channel:_handsfreeChannel];
        return;
    }
    // bluetoothd reports the service class from the SDP record; Bathys's HFP record lists both 0x111E (hands-free) and
    // 0x1203 (generic audio), and both are reported in practice (observed); 0 means none was reported. Any other value means
    // the channel number is stale (observed: the headphones' HFP channel number changes, 12 then 10 on the same day)
    BOOL handsfreeService = service16 == kBluetoothSDPUUID16ServiceClassHandsFree || service16 == kBluetoothSDPUUID16ServiceClassGenericAudio || service16 == 0;
    if (!handsfreeService) {
        // Close this one, re-read the channel number from the latest SDP cache and grab again
        close(fd);
        [_handsfreeSession closeRFCOMM:_uuid channel:_handsfreeChannel];
        uint8_t refreshed = [self handsfreeChannelFromSDP];
        BBLog(@"RFCOMM %u is not the HFP service (0x%04X), switching to channel %u from the latest SDP cache", _handsfreeChannel, service16, refreshed);
        _handsfreeChannel = refreshed;
        return;
    }
    BBLog(@"Grabbed the HFP channel: RFCOMM %u, request #%lu (earlier failures %@), MTU %u", _handsfreeChannel, (unsigned long)_handsfreeAttempts,
        _handsfreeRefusals.count ? _handsfreeRefusals : @"none", mtu);
    _gateway = [[HandsfreeGateway alloc] initWithSocket:[[L2CAPSocket alloc] initWithFD:fd outMTU:mtu]];
    _gateway.logHandler = ^(NSString *message) { BBLog(@"%@", message); };
    __weak typeof(self) weakSelf = self;
    _gateway.batteryHandler = ^(int percent) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_batteryPercent = percent;
        [strongSelf reportStatus:strongSelf->_linkStatus];
    };
    _gateway.closedHandler = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        BBLog(@"HFP channel closed");
        strongSelf->_gateway = nil;
        // From now on battery level goes to macOS (if it connects HFP); our value is void
        if (strongSelf->_batteryPercent >= 0) {
            strongSelf->_batteryPercent = -1;
            [strongSelf reportStatus:strongSelf->_linkStatus];
        }
    };
}

- (void)resetHandsfree {
    if (_gateway) {
        [_gateway close];
        _gateway = nil;
        [_handsfreeSession closeRFCOMM:_uuid channel:_handsfreeChannel];
    }
    _handsfreeLost = NO;
    _handsfreeBusyStreak = 0;
}

// The first kAvrcpSetupWindow seconds after the link comes up
- (BOOL)inAvrcpSetupWindow {
    return _linkTicks && BBTicksToSeconds(mach_absolute_time() - _linkTicks) < kAvrcpSetupWindow;
}

- (void)avrcpTick {
    if (!_avrcpSession.ready || _avrcpSession.openInFlight || _avrcp || _stopping) return;
    if (_avrcpLost && BBTicksToSeconds(mach_absolute_time() - _avrcpLostTicks) < kAvrcpRetrySeconds) return;
    if (_state == SourceStateIdle || _state == SourceStateReconnecting || _state == SourceStateOpeningMedia) return;
    if ([self settingUpStream] && ![self inAvrcpSetupWindow]) return;
    _avrcpAttempts++;
    __weak typeof(self) weakSelf = self;
    [_avrcpSession openChannel:_uuid psm:kAVCTPPSM handler:^(int result, uint16_t cid, uint16_t outMTU, int fd) {
        [weakSelf avrcpOpened:result mtu:outMTU fd:fd];
    }];
}

- (void)avrcpOpened:(int)result mtu:(uint16_t)mtu fd:(int)fd {
    if (result != 0) {
        // Refusals before the media channel opens do not count: right after the link comes up, macOS's requests and our
        // signaling requests pile up and the headphones return 454; retrying a bit later often connects
        if (_state < SourceStateMediaReady) return;
        _avrcpBusyStreak = result == 454 ? _avrcpBusyStreak + 1 : 0;
        if (_avrcpBusyStreak >= kAvrcpBusyLimit) {
            if (!_avrcpLost) {
                BBLog(@"Cannot connect the AVRCP channel (%lu consecutive 454s, held by macOS or no longer accepted by the headphones): volume is not synced with the headphones for now, using software volume, retrying every %.0f s", (unsigned long)_avrcpBusyStreak,
                    kAvrcpRetrySeconds);
                if (_remoteControlBlockedHandler) _remoteControlBlockedHandler(YES);
            }
            _avrcpLost = YES;
            _avrcpLostTicks = mach_absolute_time();
        }
        return;
    }
    if (_stopping || _state == SourceStateReconnecting || _avrcp) {
        close(fd);
        [_avrcpSession closeChannel:_uuid psm:kAVCTPPSM];
        return;
    }
    BBLog(@"Grabbed the AVRCP channel: request #%lu, outgoing MTU %u", (unsigned long)_avrcpAttempts, mtu);
    if (_avrcpLost && _remoteControlBlockedHandler) _remoteControlBlockedHandler(NO);
    _avrcpLost = NO;
    _avrcpBusyStreak = 0;
    _avrcp = [[AvrcpController alloc] initWithSocket:[[L2CAPSocket alloc] initWithFD:fd outMTU:mtu]];
    _avrcp.logHandler = ^(NSString *message) { BBLog(@"%@", message); };
    __weak typeof(self) weakSelf = self;
    _avrcp.volumeHandler = ^(int volume) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_remoteVolumeHandler) strongSelf->_remoteVolumeHandler(volume);
    };
    _avrcp.operationHandler = ^(AvrcpOperation operation) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_remoteOperationHandler) strongSelf->_remoteOperationHandler(operation);
    };
    _avrcp.closedHandler = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        BBLog(@"AVRCP channel closed");
        strongSelf->_avrcp = nil;
        if (strongSelf->_remoteVolumeHandler) strongSelf->_remoteVolumeHandler(-1);
    };
    [_avrcp start];
}

- (BOOL)setRemoteVolume:(int)volume {
    if (!_avrcp.absoluteVolumeSupported) return NO;
    [_avrcp setAbsoluteVolume:volume];
    return YES;
}

- (void)resetAvrcp {
    if (_avrcp) {
        [_avrcp close];
        _avrcp = nil;
        [_avrcpSession closeChannel:_uuid psm:kAVCTPPSM];
        if (_remoteVolumeHandler) _remoteVolumeHandler(-1);
    }
    if (_avrcpLost && _remoteControlBlockedHandler) _remoteControlBlockedHandler(NO);
    _avrcpLost = NO;
    _avrcpBusyStreak = 0;
}

- (void)raceTick {
    [self handsfreeTick];
    [self avrcpTick];
    // Start requesting without waiting for the link: macOS connects AVDTP right after SDP completes (observed about 20ms
    // before isConnected turns true), so waiting for the link is too late; requests before the link is up just fail, at little cost
    if (_state == SourceStateConnecting && _device.isConnected) [self linkReady:@"polling"];
    if (_state != SourceStateConnecting && _state != SourceStateRacing) return;
    if (_roundDeadline && mach_absolute_time() > _roundDeadline) {
        [self restartRound:[NSString stringWithFormat:@"not grabbed within %.0f s after the link came up", kRoundTimeout]];
        return;
    }
    double waited = BBTicksToSeconds(mach_absolute_time() - _roundStartTicks);
    if (_state == SourceStateConnecting && waited > 8 && !_waitHintShown) {
        _waitHintShown = YES;
        [self reportStatus:LinkStatusWaitingHeadset];
        BBLog(@"The headphones did not answer the connection (page timeout): they may be off, or connected to another device such as a phone "
              @"(they do not accept the Mac when single-point, or when multipoint is full). Disconnect on that device, or turn the "
              @"headphones off and on again; when they reconnect to this Mac the tool will grab the channels at that moment");
    }
    if (_state == SourceStateConnecting && waited > kLinkWaitTimeout) {
        [self stopWithReason:[NSString stringWithFormat:@"The headphones did not connect within %.0f s", kLinkWaitTimeout] exitCode:2];
        return;
    }
    if (_state == SourceStateConnecting && BBTicksToSeconds(mach_absolute_time() - _pageTicks) > kRepageSeconds) {
        _pageTicks = mach_absolute_time();
        BBLog(@"The headphones are still not connected, requesting a connection again (waited %.0f s)", waited);
        [_raceSessions[0] connectDevice:_uuid];
    }
    for (ClassicSession *session in _raceSessions) {
        if (!session.ready || session.openInFlight) continue;
        _attempts++;
        __weak typeof(self) weakSelf = self;
        __weak ClassicSession *weakSession = session;
        [session openChannel:_uuid psm:kAVDTPPSM handler:^(int result, uint16_t cid, uint16_t outMTU, int fd) {
            [weakSelf session:weakSession opened:result cid:cid mtu:outMTU fd:fd];
        }];
        return;
    }
}

- (void)session:(ClassicSession *)session opened:(int)result cid:(uint16_t)cid mtu:(uint16_t)mtu fd:(int)fd {
    if (result != 0) {
        // 454 = OI_L2CAP_CONNECT_REFUSED_NO_RESOURCES (AOSP embdrv/sbc/decoder/include/oi_status.h L133): the headphones already have a signaling channel
        _refusals[@(result)] = @(_refusals[@(result)].integerValue + 1);
        return;
    }
    if ((_state != SourceStateRacing && _state != SourceStateConnecting) || _stopping) {
        // A success arriving after we already won: close only this session's own channel, leaving the grabbed one alone
        close(fd);
        [session closeChannel:_uuid psm:kAVDTPPSM];
        BBLog(@"%@: late success (CID 0x%04X) closed", session.label, cid);
        return;
    }
    _signalSession = session;
    // Grabbed before the link-up event or polling reported it: count from now
    if (!_linkTicks) _linkTicks = mach_absolute_time();
    _signal = [[L2CAPSocket alloc] initWithFD:fd outMTU:mtu];
    BBLog(@"Grabbed the signaling channel: %@, request #%lu (earlier refusals %@), CID 0x%04X, outgoing MTU %u, %@", session.label, (unsigned long)_attempts,
        _refusals.count ? _refusals : @"none", cid, mtu, [_signal describeType]);
    __weak typeof(self) weakSelf = self;
    _signal.packetHandler = ^(NSData *packet) { [weakSelf signalReceived:packet]; };
    _signal.closedHandler = ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_state == SourceStateSignalReady && strongSelf->_endpoints.count == 0) {
            [strongSelf abandonSignal:@"channel closed before DISCOVER"];
        } else {
            [weakSelf stopWithReason:@"Signaling channel closed by the peer or macOS" exitCode:5];
        }
    };
    _state = SourceStateSignalReady;
    [self discover];
    // A connection grabbed while colliding with macOS opening its media channel is taken by the headphones as the system's
    // media channel (observed: closed shortly after); if DISCOVER gets no answer, give it up and keep grabbing
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && !strongSelf->_stopping && strongSelf->_state == SourceStateSignalReady && strongSelf->_endpoints.count == 0 &&
            strongSelf->_signalSession == session) {
            [strongSelf abandonSignal:@"no response to DISCOVER within 1.5 s"];
        }
    });
}

- (void)abandonSignal:(NSString *)reason {
    if (_stopping) return;
    _signal.closedHandler = nil;
    [_signal close];
    _signal = nil;
    [_signalSession closeChannel:_uuid psm:kAVDTPPSM];
    _signalSession = nil;
    _pendingReply = nil;
    _signalBuffer.length = 0;
    // A fake signaling channel usually means the system's stream is already up; grabbing more would only get 454, so go
    // straight to the next round
    [self restartRound:[NSString stringWithFormat:@"grabbed a fake signaling channel, %@", reason]];
}

#pragma mark Pairing

- (void)pair {
    BBLog(@"Device is not paired with this Mac, pairing from this tool (the headphones must be in pairing mode)");
    _pairing = [IOBluetoothDevicePair pairWithDevice:_device];
    _pairing.delegate = self;
    IOReturn result = [_pairing start];
    BBLog(@"Pairing started: IOReturn 0x%08X", result);
    if (result != kIOReturnSuccess) [self stopWithReason:@"Cannot start pairing" exitCode:2];
}

- (void)devicePairingUserConfirmationRequest:(id)sender numericValue:(BluetoothNumericValue)numericValue {
    BBLog(@"Pairing: confirmation code %06u, confirming automatically", numericValue);
    [sender replyUserConfirmation:YES];
}

- (void)devicePairingPINCodeRequest:(id)sender {
    BBLog(@"Pairing: the headphones ask for a PIN, replying 0000");
    BluetoothPINCode pin = {{'0', '0', '0', '0'}};
    [sender replyPINCode:4 PINCode:&pin];
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    _pairing = nil;
    BBLog(@"Pairing finished: IOReturn 0x%08X, paired=%d", error, _device.isPaired);
    if (error != kIOReturnSuccess) {
        [self stopWithReason:@"Pairing failed (are the headphones in pairing mode?)" exitCode:2];
        return;
    }
    // Right after pairing the headphones often leave the system's AVDTP connection pending, a good moment to get in first (observed)
    [self connect];
}

#pragma mark Signaling I/O

- (void)write:(NSData *)data {
    if (![_signal send:data]) BBLog(@"Signaling write failed: errno %d", errno);
}

- (void)sendCommand:(uint8_t)signal payload:(const uint8_t *)payload length:(size_t)length reply:(ReplyBlock)reply {
    uint8_t label = _nextLabel;
    _nextLabel = (_nextLabel + 1) & 0x0F;
    NSMutableData *packet = [NSMutableData dataWithLength:2 + length];
    uint8_t *bytes = packet.mutableBytes;
    bytes[0] = (uint8_t)(label << 4 | kPktSingle << 2 | kMsgCommand);
    bytes[1] = signal & 0x3F;
    if (length) memcpy(bytes + 2, payload, length);
    _pendingLabel = label;
    _pendingSignal = signal;
    _pendingReply = [reply copy];
    NSUInteger sequence = ++_pendingSequence;
    BBLog(@"→ %@ command  %@", SignalName(signal), BBHex(bytes, packet.length));
    [self write:packet];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRequestTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_pendingReply && self->_pendingSequence == sequence) {
            self->_pendingReply = nil;
            [self stopWithReason:[NSString stringWithFormat:@"No response to %@ within %.0f s", SignalName(signal), kRequestTimeout] exitCode:4];
        }
    });
}

- (void)respond:(uint8_t)signal label:(uint8_t)label messageType:(uint8_t)messageType payload:(const uint8_t *)payload length:(size_t)length {
    NSMutableData *packet = [NSMutableData dataWithLength:2 + length];
    uint8_t *bytes = packet.mutableBytes;
    bytes[0] = (uint8_t)(label << 4 | kPktSingle << 2 | messageType);
    bytes[1] = signal & 0x3F;
    if (length) memcpy(bytes + 2, payload, length);
    BBLog(@"→ %@ %@  %@", SignalName(signal), MessageTypeName(messageType), BBHex(bytes, packet.length));
    [self write:packet];
}

- (void)signalReceived:(NSData *)data {
    [_signalBuffer appendData:data];
    while (_signalBuffer.length > 0) {
        const uint8_t *bytes = _signalBuffer.bytes;
        size_t length = AVDTPMessageLength(bytes, _signalBuffer.length);
        if (length < _signalBuffer.length) BBLog(@"(one read contains several signals, splitting by format)");
        [self handlePacket:bytes length:length];
        [_signalBuffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
    }
}

- (void)handlePacket:(const uint8_t *)bytes length:(size_t)length {
    if (length < 1) return;
    uint8_t label = bytes[0] >> 4;
    uint8_t packetType = (bytes[0] >> 2) & 0x03;
    uint8_t messageType = bytes[0] & 0x03;
    switch (packetType) {
        case kPktSingle:
            if (length < 2) return;
            BBLog(@"← %@ %@  %@", SignalName(bytes[1] & 0x3F), MessageTypeName(messageType), BBHex(bytes, length));
            [self handleSignal:bytes[1] & 0x3F label:label messageType:messageType payload:bytes + 2 length:length - 2];
            break;
        case kPktStart:
            if (length < 3) return;
            BBLog(@"← fragment start (%u fragments)  %@", bytes[1], BBHex(bytes, length));
            _fragment = [NSMutableData dataWithBytes:bytes + 3 length:length - 3];
            _fragmentSignal = bytes[2] & 0x3F;
            _fragmentLabel = label;
            _fragmentMessageType = messageType;
            break;
        case kPktContinue:
        case kPktEnd:
            BBLog(@"← fragment %@  %@", packetType == kPktEnd ? @"end" : @"continue", BBHex(bytes, length));
            [_fragment appendBytes:bytes + 1 length:length - 1];
            if (packetType == kPktEnd && _fragment) {
                NSData *whole = _fragment;
                _fragment = nil;
                [self handleSignal:_fragmentSignal label:_fragmentLabel messageType:_fragmentMessageType payload:whole.bytes length:whole.length];
            }
            break;
    }
}

- (void)handleSignal:(uint8_t)signal label:(uint8_t)label messageType:(uint8_t)messageType payload:(const uint8_t *)payload length:(size_t)length {
    if (messageType == kMsgCommand) {
        [self handleCommand:signal label:label payload:payload length:length];
        return;
    }
    // A response must match both the command's label and its signal (observed: WH-1000XM4 answers OPEN with a reject carrying
    // signal ID DISCOVER first, then the OPEN reject)
    if (!_pendingReply || label != _pendingLabel || (messageType != kMsgGeneralReject && signal != _pendingSignal)) {
        BBLog(@"  Ignoring unmatched response (label %u)", label);
        return;
    }
    ReplyBlock reply = _pendingReply;
    _pendingReply = nil;
    if (messageType != kMsgAccept) {
        BBLog(@"  %@ got %@, error info: %@", SignalName(_pendingSignal), MessageTypeName(messageType), length ? BBHex(payload, length) : @"none");
    }
    reply(messageType, payload, length);
}

#pragma mark Answering the headphones as ACP

- (void)handleCommand:(uint8_t)signal label:(uint8_t)label payload:(const uint8_t *)payload length:(size_t)length {
    uint8_t seid = length ? payload[0] >> 2 : 0;
    switch (signal) {
        case kSigDiscover: {
            uint8_t sep[2] = {
                (uint8_t)(kLocalSeid << 2 | (_state >= SourceStateConfigured) << 1),
                (uint8_t)(kMediaAudio << 4 | kSepSource << 3),
            };
            [self respond:signal label:label messageType:kMsgAccept payload:sep length:sizeof(sep)];
            break;
        }
        case kSigGetCapabilities:
        case kSigGetAllCapabilities: {
            if (seid != kLocalSeid) {
                uint8_t error = kErrBadAcpSeid;
                [self respond:signal label:label messageType:kMsgReject payload:&error length:1];
                break;
            }
            [self respondElement:_configuration.element ?: [self defaultCapability] signal:signal label:label];
            break;
        }
        case kSigGetConfiguration: {
            if (_state < SourceStateConfigured || seid != kLocalSeid || !_configuration) {
                uint8_t error = kErrBadState;
                [self respond:signal label:label messageType:kMsgReject payload:&error length:1];
                break;
            }
            [self respondElement:_configuration.element signal:signal label:label];
            break;
        }
        case kSigDelayReport:
            // Delay is big-endian 16-bit in units of 0.1ms: BlueZ avdtp.c struct delay_req and L2054 ntohs(req->delay)
            if (length >= 3) {
                _headsetDelayMs = (payload[1] << 8 | payload[2]) / 10.0;
                BBLog(@"  Headphones report playback delay %.1f ms", _headsetDelayMs);
            }
            [self respond:signal label:label messageType:kMsgAccept payload:NULL length:0];
            break;
        case kSigStart:
            [self respond:signal label:label messageType:kMsgAccept payload:NULL length:0];
            if (_state == SourceStateMediaReady) [self beginStreaming];
            break;
        case kSigSuspend:
            [self respond:signal label:label messageType:kMsgAccept payload:NULL length:0];
            if (_state == SourceStateStreaming) {
                [_streamer pause];
                _state = SourceStateMediaReady;
            }
            break;
        case kSigClose:
        case kSigAbort:
            [self respond:signal label:label messageType:kMsgAccept payload:NULL length:0];
            if (signal == kSigAbort && _pendingReply && _pendingSignal == kSigAbort) {
                // We are sending ABORT to reconfigure and the headphones' ABORT crossed it (2026-10-15 05:29:07 Bathys, after
                // the media channel was refused): the stream is aborted, carry on without waiting for the reply to ours (the
                // headphones may never send it); a late reply will not match the label and is ignored
                BBLog(@"The headphones' ABORT crossed ours, stream aborted, reconfiguring as usual");
                ReplyBlock reply = _pendingReply;
                _pendingReply = nil;
                reply(kMsgAccept, NULL, 0);
                break;
            }
            [self stopWithReason:[NSString stringWithFormat:@"Headphones sent %@", SignalName(signal)] exitCode:SourceExitHeadsetBusy];
            break;
        case kSigSetConfiguration:
        case kSigReconfigure: {
            // We always configure the headphones as INT and do not accept configuration the other way; reject format is
            // [service category, error code]
            uint8_t reject[2] = { kCatMediaCodec, kErrBadState };
            [self respond:signal label:label messageType:kMsgReject payload:reject length:sizeof(reject)];
            break;
        }
        case kSigOpen:
        case kSigSecurityControl: {
            uint8_t error = kErrNotSupportedCommand;
            [self respond:signal label:label messageType:kMsgReject payload:&error length:1];
            break;
        }
        default:
            [self respond:signal label:label messageType:kMsgGeneralReject payload:NULL length:0];
            break;
    }
}

// Before configuration, our SEP's capability is answered with the mandatory SBC set: 44.1k/48k, all channel modes, block
// lengths, subbands, allocation methods, bitpool 2–53 (A2DP spec 4.3.2)
- (NSData *)defaultCapability {
    uint8_t sbc[] = { kMediaAudio << 4, kCodecSBC, 0x3F, 0xFF, 2, 53 };
    return [NSData dataWithBytes:sbc length:sizeof(sbc)];
}

- (void)respondElement:(NSData *)element signal:(uint8_t)signal label:(uint8_t)label {
    NSMutableData *reply = [NSMutableData data];
    uint8_t head[] = { kCatMediaTransport, 0, kCatMediaCodec, (uint8_t)element.length };
    [reply appendBytes:head length:sizeof(head)];
    [reply appendData:element];
    [self respond:signal label:label messageType:kMsgAccept payload:reply.bytes length:reply.length];
}

#pragma mark Querying capabilities as INT

- (void)discover {
    [self sendCommand:kSigDiscover payload:NULL length:0 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
        if (messageType != kMsgAccept) {
            [self stopWithReason:@"DISCOVER rejected" exitCode:3];
            return;
        }
        for (size_t i = 0; i + 1 < length; i += 2) {
            SinkEndpoint *endpoint = [SinkEndpoint new];
            endpoint.seid = payload[i] >> 2;
            endpoint.inUse = (payload[i] >> 1) & 1;
            endpoint.mediaType = payload[i + 1] >> 4;
            endpoint.sepType = (payload[i + 1] >> 3) & 1;
            [self->_endpoints addObject:endpoint];
            BBLog(@"  Endpoint SEID %u: %@ %@%@", endpoint.seid,
                endpoint.mediaType == kMediaAudio ? @"audio" : [NSString stringWithFormat:@"media type %u", endpoint.mediaType],
                endpoint.sepType == kSepSink ? @"Sink" : @"Source", endpoint.inUse ? @", in use" : @"");
        }
        [self queryCapabilitiesAtIndex:0];
    }];
}

- (void)queryCapabilitiesAtIndex:(NSUInteger)index {
    if (index >= _endpoints.count) {
        [self capabilitiesDone];
        return;
    }
    SinkEndpoint *endpoint = _endpoints[index];
    if (endpoint.mediaType != kMediaAudio || endpoint.sepType != kSepSink) {
        [self queryCapabilitiesAtIndex:index + 1];
        return;
    }
    uint8_t request = (uint8_t)(endpoint.seid << 2);
    uint8_t signal = _useGetAllCapabilities ? kSigGetAllCapabilities : kSigGetCapabilities;
    [self sendCommand:signal payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
        if (messageType != kMsgAccept) {
            if (self->_useGetAllCapabilities) {
                // The peer may only support AVDTP 1.2 or earlier; fall back to GET_CAPABILITIES and retry
                self->_useGetAllCapabilities = NO;
                [self queryCapabilitiesAtIndex:index];
            } else {
                [self queryCapabilitiesAtIndex:index + 1];
            }
            return;
        }
        [self parseCapabilities:payload length:length endpoint:endpoint];
        [self queryCapabilitiesAtIndex:index + 1];
    }];
}

- (void)parseCapabilities:(const uint8_t *)payload length:(size_t)length endpoint:(SinkEndpoint *)endpoint {
    size_t offset = 0;
    while (offset + 2 <= length) {
        uint8_t category = payload[offset];
        uint8_t size = payload[offset + 1];
        const uint8_t *data = payload + offset + 2;
        if (offset + 2 + size > length) break;
        if (category == kCatMediaCodec && size >= 2) {
            endpoint.codecElement = [NSData dataWithBytes:data length:size];
            endpoint.codec = [A2DPCodec codecForElement:endpoint.codecElement];
            BBLog(@"  SEID %u codec: %@", endpoint.seid, [A2DPCodec describeElement:endpoint.codecElement]);
        } else if (category == kCatDelayReporting) {
            endpoint.delayReporting = YES;
        } else if (category == kCatContentProtection && size >= 2) {
            BBLog(@"  SEID %u content protection type 0x%04X", endpoint.seid, A2DPReadLE16(data));
        }
        offset += 2 + size;
    }
}

- (void)capabilitiesDone {
    NSMutableArray<RemoteCodec *> *codecs = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (SinkEndpoint *endpoint in _endpoints) {
        if (!endpoint.codecElement) continue;
        RemoteCodec *codec = [A2DPCodec remoteCodecForElement:endpoint.codecElement];
        // One codec may have several endpoints (the XM4 keeps two sets per codec for multipoint); report it once; endpoint
        // selection tries endpoints one by one separately
        if ([names containsObject:codec.name]) continue;
        [codecs addObject:codec];
        [names addObject:codec.name];
    }
    _remoteCodecs = codecs;
    BBLog(@"Result: the headphones declare %@", names.count ? [names componentsJoinedByString:@", "] : @"(no audio Sink endpoint)");
    if (_mode == SourceModeProbe) {
        [self stopWithReason:@"Probe complete" exitCode:0];
        return;
    }
    if (_capabilitiesHandler && !_capabilitiesHandler(codecs)) {
        _handToSystem = YES;
        [self stopWithReason:@"None of the headphones' codecs beats the system's, handing the connection back to macOS" exitCode:SourceExitHandedToSystem];
        return;
    }
    [self configureAfterLinkSettles];
}

// Right after the link comes up, hold off configuring until bluetoothd's round of connection attempts has passed
// (kConfigureAfterLinkSeconds); keep grabbing the AVRCP channel meanwhile
- (void)configureAfterLinkSettles {
    double remaining = _linkTicks ? kConfigureAfterLinkSeconds - BBTicksToSeconds(mach_absolute_time() - _linkTicks) : 0;
    if (remaining <= 0) {
        [self configure];
        return;
    }
    BBLog(@"Link just came up, waiting %.0f ms for the system's round of connection attempts to pass before configuring%@", remaining * 1000, _avrcp ? @"" : @" (still connecting the AVRCP channel meanwhile)");
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && !strongSelf->_stopping && strongSelf->_state == SourceStateSignalReady) [strongSelf configure];
    });
}

#pragma mark Choosing codec and sample rate

- (double)captureDeviceRate {
    return _useVirtualDevice ? _systemAudio.deviceSampleRate : _systemAudio.sampleRate;
}

// Codec choice: the user's preferred codec first, then by priority; the sample rate is picked within the chosen codec
// (details below). Decides only, changes no state (can also be used while streaming to see whether to reconfigure)
- (CodecChoice *)chooseCodec {
    NSMutableArray<CodecID> *order = [NSMutableArray array];
    if (_options.preferredCodec) [order addObject:_options.preferredCodec];
    for (CodecID codec in _options.priority) {
        if (![order containsObject:codec]) [order addObject:codec];
    }
    NSMutableArray<SinkEndpoint *> *candidates = [NSMutableArray array];
    for (CodecID codec in order) {
        SinkEndpoint *best = nil;
        for (SinkEndpoint *endpoint in _endpoints) {
            if (![endpoint.codec.identifier isEqualToString:codec]) continue;
            // Several endpoints for one codec (e.g. SEID 3 and 6 on WH-1000XM4): prefer one not in use and not reported busy this time
            if (!best || (best.inUse && !endpoint.inUse) || (best.busy && !endpoint.busy && !endpoint.inUse)) best = endpoint;
        }
        if (best) [candidates addObject:best];
    }
    // A process tap follows the system output device, so its sample rate cannot be changed; the virtual device is set by this
    // session (except values already tried and found unsettable); test tone and file can use anything
    BOOL fixedRate = _systemAudio && !_useVirtualDevice;
    double current = _systemAudio ? [self captureDeviceRate] : 0;
    double desired = fixedRate ? current : (_desiredSampleRate ?: (current ?: (_requestedRate ?: 48000)));
    // Pick the codec by priority first (the preferred codec at the front), then pick the sample rate among those this codec
    // supports: exact match, same family, finally cross-family (48k preferred); macOS resamples the difference. Same as Android
    // (a2dp_vendor_*.cc: user preference → audio config → default → best) and PipeWire (media_codec_select_config, default
    // target 48000): neither changes codec because of the source sample rate.
    // We used to filter all codecs by "same family" first: a 44.1k track knocked out codecs that only support 48k and fell
    // back to a lower codec, even when one was preferred (2026-10-14 02:26)
    CodecChoice *choice = [CodecChoice new];
    for (SinkEndpoint *endpoint in candidates) {
        CodecID codec = endpoint.codec.identifier;
        CodecFallbackReason reason = CodecFallbackNone;
        double rate = 0;
        if (_failedCodecs[codec]) {
            reason = (CodecFallbackReason)_failedCodecs[codec].integerValue;
        } else if (endpoint.inUse) {
            reason = CodecFallbackEndpointBusy;
        } else {
            NSMutableArray<NSNumber *> *rates = [NSMutableArray array];
            for (NSNumber *value in [endpoint.codec sampleRatesInCapability:endpoint.codecElement]) {
                if (_options.maxSampleRate > 0 && value.doubleValue > _options.maxSampleRate) continue;
                if (_useVirtualDevice && [_unsettableRates containsObject:value] && value.doubleValue != current) continue;
                [rates addObject:value];
            }
            rate = fixedRate ? ([rates containsObject:@(current)] ? current : 0) : A2DPBestSampleRate(rates, desired, NO);
            if (!rate) reason = CodecFallbackUnsupportedRate;
        }
        if (rate) {
            CodecConfiguration *configuration = [endpoint.codec configurationForCapability:endpoint.codecElement sampleRate:rate options:_options];
            if (configuration) {
                choice.endpoint = endpoint;
                choice.configuration = configuration;
                break;
            }
            reason = CodecFallbackUnsupportedRate;
        }
        // Report to the UI the first higher-priority codec that could not be used
        if (!choice.fallbackCodec) {
            choice.fallbackCodec = codec;
            choice.fallbackReason = reason;
        }
    }
    return choice;
}

// Choose a codec for the current options and sample rate and configure it (used for the first time, after sample rate or
// option changes, codec failures, and retries after the media channel was taken)
- (void)configure {
    if (_stopping) return;
    CodecChoice *choice = [self chooseCodec];
    _fallbackCodec = choice.fallbackCodec;
    _fallbackReason = choice.fallbackReason;
    if (!choice.endpoint) {
        // With unchanged conditions a retry fails the same way: hand back to macOS and take over again once settings change
        // (StreamController does not reconnect automatically)
        _handToSystem = YES;
        [self stopWithReason:@"None of the codecs the headphones declare is usable here right now, handing the connection back to macOS" exitCode:SourceExitHandedToSystem];
        return;
    }
    A2DPCodec *codec = choice.endpoint.codec;
    NSString *error = nil;
    if (![codec prepareWithError:&error]) {
        BBLog(@"%@ encoder unavailable (%@), moving to the next codec by priority", codec.displayName, error);
        _failedCodecs[codec.identifier] = @(CodecFallbackEncoderUnavailable);
        [self configure];
        return;
    }
    double rate = choice.configuration.sampleRate;
    if (_useVirtualDevice && _systemAudio && [self captureDeviceRate] != rate) {
        [self requestDeviceRate:rate];
        return;
    }
    if (_systemAudio && _systemAudio.sampleRate != rate && ![self replaceCaptureSource]) return;
    if (_fallbackCodec) {
        BBLog(@"Could not use %@ (%@), using %@ instead", [A2DPCodec codecWithID:_fallbackCodec].displayName ?: _fallbackCodec,
            FallbackReasonText(_fallbackReason), codec.displayName);
    }
    [self sendConfiguration:choice.configuration endpoint:choice.endpoint];
}

static NSString *FallbackReasonText(CodecFallbackReason reason) {
    switch (reason) {
        case CodecFallbackNone: return @"none";
        case CodecFallbackUnsupportedRate: return @"sample rate not supported";
        case CodecFallbackEncoderUnavailable: return @"encoder cannot be opened";
        case CodecFallbackRejected: return @"headphones rejected the configuration";
        case CodecFallbackEncoderFailed: return @"encoder error";
        case CodecFallbackEndpointBusy: return @"endpoint in use";
    }
    return @"?";
}

// Change the virtual device's nominal sample rate and configure once the driver applies it (sample rate change notification);
// if it has not taken effect within 2 s (e.g. an old driver that does not support that rate), note it and re-choose at the
// current sample rate
- (void)requestDeviceRate:(double)rate {
    double from = [self captureDeviceRate];
    _awaitingRate = rate;
    NSUInteger attempt = ++_rateRequests;
    BOOL ok = [_systemAudio setDeviceSampleRate:rate];
    BBLog(@"Virtual device sample rate %g → %g kHz%@", from / 1000, rate / 1000, ok ? @"" : @" (setting failed)");
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (ok ? 2 : 0) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_stopping || strongSelf->_awaitingRate != rate || strongSelf->_rateRequests != attempt) return;
        strongSelf->_awaitingRate = 0;
        if ([strongSelf captureDeviceRate] != rate) {
            BBLog(@"Virtual device did not switch to %g kHz (the driver may need updating), re-choosing at the current sample rate", rate / 1000);
            [strongSelf->_unsettableRates addObject:@(rate)];
        }
        [strongSelf configure];
    });
}

- (void)sendConfiguration:(CodecConfiguration *)configuration endpoint:(SinkEndpoint *)endpoint {
    if (endpoint != _chosen) _configureRetries = 0;
    _chosen = endpoint;
    _codec = endpoint.codec;
    _configuration = configuration;
    NSMutableData *request = [NSMutableData data];
    uint8_t head[] = { (uint8_t)(endpoint.seid << 2), kLocalSeid << 2, kCatMediaTransport, 0, kCatMediaCodec, (uint8_t)configuration.element.length };
    [request appendBytes:head length:sizeof(head)];
    [request appendData:configuration.element];
    if (endpoint.delayReporting) {
        uint8_t delay[] = { kCatDelayReporting, 0 };
        [request appendBytes:delay length:sizeof(delay)];
    }
    BBLog(@"Configuring SEID %u: %@", endpoint.seid, configuration.summary);
    [self sendCommand:kSigSetConfiguration payload:request.bytes length:request.length reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
        if (messageType != kMsgAccept) {
            // 0x31 BAD_STATE: the headphone endpoint is not idle yet (the previous stream's channels are not released);
            // 0x13 SEP_IN_USE: the endpoint is held by another connection
            BOOL badState = messageType == kMsgReject && length >= 2 && (payload[1] == kErrBadState || payload[1] == kErrSepInUse);
            if (badState && !endpoint.busy) {
                endpoint.busy = YES;
                // Observed (2026-10-13 19:35:21, WH-1000XM4): after ABORT, SEID 3 returned 0x31 for 2 s straight; it also has
                // SEID 6, another LDAC endpoint
                SinkEndpoint *alternate = [self idleEndpointLike:endpoint];
                if (alternate) {
                    BBLog(@"SEID %u not idle (0x%02X), configuring SEID %u with the same codec instead", endpoint.seid, payload[1], alternate.seid);
                    [self configure];
                    return;
                }
            }
            if (badState && self->_configureRetries < kConfigureRetries) {
                self->_configureRetries++;
                BBLog(@"Headphone endpoint not idle yet (0x31), reconfiguring in 0.5 s (attempt %lu)", (unsigned long)self->_configureRetries);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    if (!self->_stopping) [self configure];
                });
                return;
            }
            if (badState) {
                // An endpoint that never frees up is a temporary state, not a problem with this codec: end this session and
                // let the controller reconnect later
                [self stopWithReason:@"Headphone endpoint never became idle (0x31)" exitCode:SourceExitHeadsetBusy];
                return;
            }
            BBLog(@"SET_CONFIGURATION for %@ rejected: %@, moving to the next codec by priority", self->_codec.displayName, BBHex(payload, length));
            self->_failedCodecs[self->_codec.identifier] = @(CodecFallbackRejected);
            self->_configuration = nil;
            [self configure];
            return;
        }
        self->_configureRetries = 0;
        self->_openRetries = 0;
        self->_state = SourceStateConfigured;
        [self openWhenQuiet:0];
    }];
}

#pragma mark Stream setup and streaming

// Before sending OPEN, wait until our own other in-flight channel requests have a result: the other signaling sessions,
// HFP, AVRCP. The media channel must be opened right after OPEN, and if its request is in flight together with others,
// WH-1000XM4 returns an L2CAP Command Reject (reason 2 invalid CID, OI 445) and the stream is dead. Observed 2026-10-13
// 21:03:33: after grabbing signaling, the other sessions' requests kept returning for a few hundred ms; one returned 454 at
// .453 and the media channel was refused at .457. Before OPEN the headphones do not treat any connection as the media
// channel, so waiting here is safe. Wait at most 1.5 s
static const NSUInteger kQuietPollLimit = 75;
static const double kQuietPollInterval = 0.02;

- (NSUInteger)otherRequestsInFlight {
    NSUInteger count = 0;
    for (ClassicSession *session in _raceSessions) {
        if (session.openInFlight) count++;
    }
    if (_handsfreeSession.rfcommInFlight) count++;
    if (_avrcpSession.openInFlight) count++;
    return count;
}

- (void)openWhenQuiet:(NSUInteger)polls {
    if (_stopping || _state != SourceStateConfigured) return;
    NSUInteger inFlight = [self otherRequestsInFlight];
    if (inFlight && polls < kQuietPollLimit) {
        if (polls == 0) BBLog(@"%lu channel requests still in flight, waiting for them to return before sending OPEN", (unsigned long)inFlight);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQuietPollInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self openWhenQuiet:polls + 1];
        });
        return;
    }
    if (polls) {
        BBLog(@"%@, sending OPEN after waiting %.0f ms", inFlight ? [NSString stringWithFormat:@"%lu requests still in flight", (unsigned long)inFlight] : @"All in-flight requests have returned",
            polls * kQuietPollInterval * 1000);
    }
    [self open];
}

// Another endpoint with the same codec that is not in use and has not reported busy this time
- (nullable SinkEndpoint *)idleEndpointLike:(SinkEndpoint *)endpoint {
    for (SinkEndpoint *other in _endpoints) {
        if (other != endpoint && other.codec == endpoint.codec && !other.inUse && !other.busy) return other;
    }
    return nil;
}

- (void)open {
    uint8_t request = (uint8_t)(_chosen.seid << 2);
    SinkEndpoint *endpoint = _chosen;
    [self sendCommand:kSigOpen payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
        if (messageType != kMsgAccept) {
            // Observed (2026-10-13 19:35:29, 19:35:36, WH-1000XM4): while the headphones were also setting up the HFP
            // connection with us, OPEN returned 0x31; every OPEN sent after HFP was up was accepted. The endpoint is still
            // configured, so resend after a short wait
            BOOL badState = messageType == kMsgReject && length >= 1 && payload[0] == kErrBadState;
            if (badState && self->_openRetries < kOpenRetries) {
                self->_openRetries++;
                BBLog(@"OPEN returned 0x31, resending in %.1f s (attempt %lu)", kOpenRetryInterval, (unsigned long)self->_openRetries);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOpenRetryInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!self->_stopping && self->_state == SourceStateConfigured && self->_chosen == endpoint) [self open];
                });
                return;
            }
            if ([self abortAndTryAlternate:@": OPEN keeps being rejected"]) return;
            [self stopWithReason:@"OPEN rejected" exitCode:SourceExitHeadsetBusy];
            return;
        }
        [self openMedia];
    }];
}

// Stream setup failed on the current endpoint: abort this stream (ABORT is valid in any state and requires both sides to
// release the stream's channels) and retry on another endpoint with the same codec; returns NO if there is none.
// Observed (2026-10-13 19:50:31, WH-1000XM4, also connected to an iPhone): OPEN on SEID 3 was accepted but START returned
// 0x12 (invalid endpoint); another time OPEN returned 0x31 six times in a row. It has two sets of endpoints (1–3, 4–6);
// with multipoint, one set may belong to the other device
- (BOOL)abortAndTryAlternate:(NSString *)reason {
    SinkEndpoint *failed = _chosen;
    failed.busy = YES;
    SinkEndpoint *alternate = [self idleEndpointLike:failed];
    if (!alternate) return NO;
    BBLog(@"SEID %u%@, aborting this stream and configuring SEID %u with the same codec instead", failed.seid, reason, alternate.seid);
    _state = SourceStateSignalReady;
    if (_media) {
        _media.closedHandler = nil;
        [_media close];
        _media = nil;
        [_mediaSession closeChannel:_uuid psm:kAVDTPPSM];
    }
    uint8_t request = (uint8_t)(failed.seid << 2);
    __weak typeof(self) weakSelf = self;
    [self sendCommand:kSigAbort payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf && !strongSelf->_stopping) [strongSelf configure];
        });
    }];
    return YES;
}

- (void)openMedia {
    // After OPEN is accepted, the INT opens a second L2CAP channel on the same PSM as the media transport channel
    _state = SourceStateOpeningMedia;
    __weak typeof(self) weakSelf = self;
    [_mediaSession openChannel:_uuid psm:kAVDTPPSM handler:^(int result, uint16_t cid, uint16_t outMTU, int fd) {
        [weakSelf mediaOpened:result cid:cid mtu:outMTU fd:fd];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_state == SourceStateOpeningMedia) [strongSelf stopWithReason:@"Media channel did not open within 10 s" exitCode:2];
    });
}

- (void)mediaOpened:(int)result cid:(uint16_t)cid mtu:(uint16_t)mtu fd:(int)fd {
    if (_state != SourceStateOpeningMedia || _stopping) {
        if (fd >= 0) close(fd);
        return;
    }
    if (result != 0) {
        if (_mediaRetries >= kMediaRetries) {
            [self stopWithReason:[NSString stringWithFormat:@"Media channel refused (result %d), already reopened %lu times", result, (unsigned long)_mediaRetries] exitCode:2];
            return;
        }
        // Observed (2026-10-12 04:52:43): after we took HFP, macOS failed to connect HFP and immediately connected A2DP; its
        // AVDTP connection request landed right after our OPEN was accepted and the headphones took it as this stream's media
        // channel, so our own request got 454.
        // Use ABORT rather than CLOSE: after CLOSE the INT must release the transport channel, but that channel is in macOS's
        // hands, so the headphones stay stuck closing and reconfiguring gets 0x31 (observed 05:22:32); ABORT requires both
        // sides to release all of the stream's channels (the AVDTP spec's Abort procedure), and the headphones drop that
        // connection themselves
        _mediaRetries++;
        // 454 = refused by the headphones (no resources): most likely a system connection request landed in the media channel
        // first; 445 = the headphones returned an L2CAP Command Reject (OI_L2CAP_CMD_REJECT_RCVD)
        NSString *why = result == 454 ? @"most likely a system connection request landed in the media channel first" : result == 445 ? @"the headphones returned an L2CAP Command Reject" : @"unknown reason";
        BBLog(@"Media channel refused (result %d, %@), aborting this stream and reconfiguring (attempt %lu)", result, why, (unsigned long)_mediaRetries);
        _state = SourceStateSignalReady;
        uint8_t request = (uint8_t)(_chosen.seid << 2);
        __weak typeof(self) weakSelf = self;
        [self sendCommand:kSigAbort payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (strongSelf && !strongSelf->_stopping) [strongSelf configure];
            });
        }];
        return;
    }
    _media = [[L2CAPSocket alloc] initWithFD:fd outMTU:mtu];
    BBLog(@"Media channel open: CID 0x%04X, outgoing MTU %u, %@", cid, mtu, [_media describeType]);
    __weak typeof(self) weakSelf = self;
    _media.packetHandler = ^(NSData *packet) { BBLog(@"Media channel received %lu bytes (ignored)", (unsigned long)packet.length); };
    _media.closedHandler = ^{ [weakSelf stopWithReason:@"Media channel closed by the peer or macOS" exitCode:5]; };
    _state = SourceStateMediaReady;
    [self sendStart];
}

- (void)sendStart {
    uint8_t request = (uint8_t)(_chosen.seid << 2);
    [self sendCommand:kSigStart payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
        if (messageType != kMsgAccept) {
            if ([self abortAndTryAlternate:@": START rejected"]) return;
            [self stopWithReason:@"START rejected" exitCode:SourceExitHeadsetBusy];
            return;
        }
        [self beginStreaming];
    }];
}

- (void)beginStreaming {
    _state = SourceStateStreaming;
    if (!_streamer) {
        id<PCMSource> source = nil;
        if (_systemAudio) {
            NSString *error = nil;
            if (![_systemAudio start:&error]) {
                [self stopWithReason:error exitCode:7];
                return;
            }
            source = _systemAudio;
            BBLog(_useVirtualDevice ? @"Taking audio from the virtual device: select it as the output in Sound settings; press Ctrl-C to stop"
                                    : @"Capturing system audio: the Mac speakers are muted while streaming; press Ctrl-C to stop and restore");
        } else if (_filePath) {
            NSError *error = nil;
            source = [[FileSource alloc] initWithPath:_filePath rate:_configuration.sampleRate error:&error];
            if (!source) {
                [self stopWithReason:[NSString stringWithFormat:@"Cannot read audio file: %@", error.localizedDescription] exitCode:7];
                return;
            }
        } else {
            source = [[ToneSource alloc] initWithRate:_configuration.sampleRate seconds:_seconds];
            BBLog(@"Test tone: left 440Hz, right 660Hz, %.0f s", _seconds);
        }
        // The virtual device sample rate changed during configuration (changed externally, or the requested rate took effect
        // only after the timeout): if the capture source does not match the configuration, reconfigure to avoid pitch shift
        if (_systemAudio && _systemAudio.sampleRate != _configuration.sampleRate) {
            [self reconfigure:[NSString stringWithFormat:@"capture source %g kHz does not match configured %g kHz", _systemAudio.sampleRate / 1000,
                               _configuration.sampleRate / 1000]];
            return;
        }
        NSString *error = nil;
        id<A2DPEncoder> encoder = [_codec encoderForConfiguration:_configuration outMTU:_media.outMTU options:_options error:&error];
        if (!encoder) {
            BBLog(@"%@ encoder creation failed: %@", _codec.displayName, error);
            _failedCodecs[_codec.identifier] = @(CodecFallbackEncoderUnavailable);
            [self reconfigure:@"encoder creation failed"];
            return;
        }
        _streamer = [[MediaStreamer alloc] initWithSocket:_media rate:_configuration.sampleRate source:source encoder:encoder label:_codec.displayName];
        __weak typeof(self) weakSelf = self;
        _streamer.failureHandler = ^(NSString *reason) { [weakSelf encoderFailed:reason]; };
        _streamer.stallHandler = ^(double maxKbps) { [weakSelf mediaStalled:maxKbps]; };
        _streamer.finishedHandler = ^{ [weakSelf stopWithReason:@"Audio playback finished" exitCode:0]; };
    }
    BBLog(@"START accepted, streaming %@", _configuration.summary);
    _idleSuspended = NO;
    [self reportStatus:LinkStatusStreaming];
    [_streamer start];
    if (_systemAudio && !_idleTimer) {
        __weak typeof(self) weakSelf = self;
        _idleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_idleTimer, DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(_idleTimer, ^{ [weakSelf idleTick]; });
        dispatch_resume(_idleTimer);
    }
}

- (double)recentKbps {
    return _state == SourceStateStreaming ? _streamer.recentKbps : 0;
}

// Encoder error while streaming: with live capture (idle timer present), close the stream within this session and switch to
// the next codec by priority without disconnecting the headphones; otherwise end the session
- (void)encoderFailed:(NSString *)reason {
    if (_stopping) return;
    _failedCodecs[_codec.identifier] = @(CodecFallbackEncoderFailed);
    if (!_idleTimer) {
        [self stopWithReason:reason exitCode:7];
        return;
    }
    _pendingReconfigure = YES;
}

// Media channel stalled: the audio path on the headphones must be rebuilt to recover, so abort this stream and reconfigure
// (recoverStalledStream; not counted as a codec failure, codec unchanged); when the CLI is streaming a test tone, end the
// session. If the encoder decides the bitrate was too high, record the cap so the encoder after reconfiguring no longer uses
// such a high bitrate
- (void)mediaStalled:(double)maxKbps {
    if (_stopping) return;
    if (maxKbps > 0 && _codec) {
        CodecOptions *options = [_options copy];
        NSMutableDictionary *limits = [options.maxKbps mutableCopy];
        limits[_codec.identifier] = @(maxKbps);
        options.maxKbps = limits;
        _options = options;
        if (_codecLimitHandler) _codecLimitHandler(_codec.identifier, maxKbps);
    }
    if (!_idleTimer) {
        [self stopWithReason:@"Media channel stalled, the headphones no longer accept data" exitCode:7];
        return;
    }
    _pendingStallRecovery = YES;
}

// Recovery after the media channel stalls: close the media channel, ABORT (valid in any state, requires both sides to release
// this stream's channels), then reconfigure; if the headphones do not even answer ABORT, the session ends on request timeout
// and reconnects. Not SUSPEND→CLOSE: on 2026-10-14 00:41, after Bathys froze, SUSPEND got no response for 5 s, the session
// failed, and disconnecting and reconnecting took 45 s
- (void)recoverStalledStream {
    BBLog(@"Media channel stalled, aborting this stream and reconfiguring");
    _commandInFlight = YES;
    _pendingReconfigure = NO;
    [_streamer pause];
    [_streamer logTotals];
    _streamer = nil;
    [_systemAudio stop];
    _state = SourceStateSignalReady;
    _mediaRetries = 0;
    if (_media) {
        _media.closedHandler = nil;
        [_media close];
        _media = nil;
        [_mediaSession closeChannel:_uuid psm:kAVDTPPSM];
    }
    _configuration = nil;
    uint8_t request = (uint8_t)(_chosen.seid << 2);
    [self sendCommand:kSigAbort payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            self->_commandInFlight = NO;
            if (self->_stopping) return;
            if (self->_systemAudio && ![self replaceCaptureSource]) return;
            [self configure];
        });
    }];
}

#pragma mark Idle suspend, sample rate and option changes

- (void)idleTick {
    if (_commandInFlight || _stopping) return;
    if (_pendingStallRecovery) {
        if (_state == SourceStateStreaming || _state == SourceStateMediaReady) {
            _pendingStallRecovery = NO;
            [self recoverStalledStream];
        }
        return;
    }
    if (_pendingReconfigure) {
        if (_state == SourceStateStreaming || _state == SourceStateMediaReady) {
            _pendingReconfigure = NO;
            [self reconfigure:@"codec, sample rate or options changed"];
        }
        return;
    }
    double quiet = _systemAudio.secondsSinceSound;
    // Playback status reported to the headphones: streaming and sound within the last 1 s
    _avrcp.playing = _state == SourceStateStreaming && quiet < 1;
    if (_state == SourceStateMediaReady && _idleSuspended) [_systemAudio keepRecentOnly];
    if (_state == SourceStateStreaming && quiet > kIdleSuspendSeconds) {
        _commandInFlight = YES;
        uint8_t request = (uint8_t)(_chosen.seid << 2);
        [self sendCommand:kSigSuspend payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
            self->_commandInFlight = NO;
            if (messageType != kMsgAccept || self->_state != SourceStateStreaming) return;
            [self->_streamer pause];
            self->_state = SourceStateMediaReady;
            self->_idleSuspended = YES;
            self->_suspendedTicks = mach_absolute_time();
            [self reportStatus:LinkStatusIdle];
            BBLog(@"Silent for %.0f s, suspending the stream (SUSPEND); resumes automatically when there is sound", kIdleSuspendSeconds);
        }];
    } else if (_state == SourceStateMediaReady && _idleSuspended && quiet < 0.5 &&
               BBTicksToSeconds(mach_absolute_time() - _suspendedTicks) > 1) {
        _commandInFlight = YES;
        BBLog(@"Sound detected, resuming the stream");
        uint8_t request = (uint8_t)(_chosen.seid << 2);
        [self sendCommand:kSigStart payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
            self->_commandInFlight = NO;
            if (messageType != kMsgAccept) {
                [self stopWithReason:@"START rejected when resuming the stream" exitCode:SourceExitHeadsetBusy];
                return;
            }
            [self beginStreaming];
        }];
    }
}

- (void)updateOptions:(CodecOptions *)options {
    BOOL newPreference = options.preferredCodec && ![options.preferredCodec isEqualToString:_options.preferredCodec ?: @""];
    _options = [options copy];
    // The user just changed the preferred codec: retry it even if it failed before (other setting changes do not clear
    // failures, to avoid repeated retries interrupting playback)
    if (newPreference) [_failedCodecs removeObjectForKey:_options.preferredCodec];
    [self reconsiderConfiguration:@"Codec options changed"];
}

- (void)setDesiredSampleRate:(double)rate {
    if (rate == _desiredSampleRate) return;
    _desiredSampleRate = rate;
    [self reconsiderConfiguration:[NSString stringWithFormat:@"Desired sample rate changed to %g kHz", rate / 1000]];
}

// When configured, check whether the codec and configuration chosen under the new conditions differ from the current ones;
// if so, close the stream and reconfigure at a safe moment
- (void)reconsiderConfiguration:(NSString *)reason {
    if (_state < SourceStateConfigured || !_configuration) return;
    CodecChoice *choice = [self chooseCodec];
    BOOL same = choice.endpoint == _chosen && [choice.configuration.element isEqualToData:_configuration.element] &&
                (choice.configuration.parameters == _configuration.parameters || [choice.configuration.parameters isEqualToDictionary:_configuration.parameters]);
    if (same) return;
    // Configuration bytes unchanged, only encoder parameters changed (LDAC tier, AAC bitrate): no renegotiation needed, just
    // swap the encoder (the LDAC tier is not part of the AVDTP configuration anyway).
    // Observed (2026-10-13 20:30:12, WH-1000XM4 streaming at 990 kbps): after closing the stream (CLOSE) to change tier, the
    // headphones stopped answering at baseband right away and the link timed out and dropped 5 s later
    if (choice.endpoint == _chosen && [choice.configuration.element isEqualToData:_configuration.element] &&
        [self swapEncoderFor:choice.configuration reason:reason]) {
        return;
    }
    BBLog(@"%@: switching to %@, will reconfigure", reason, choice.configuration.summary ?: @"(no usable codec)");
    _pendingReconfigure = YES;
}

- (BOOL)swapEncoderFor:(CodecConfiguration *)configuration reason:(NSString *)reason {
    if (!_streamer) {
        // Not streaming yet: the encoder is built from the new configuration when streaming starts
        _configuration = configuration;
        BBLog(@"%@: switching to %@ (encoder parameters only, no renegotiation)", reason, configuration.summary);
        return YES;
    }
    if ([_streamer applyConfiguration:configuration]) {
        _configuration = configuration;
        BBLog(@"%@: switching to %@ while streaming (applied in place by the encoder)", reason, configuration.summary);
        return YES;
    }
    A2DPCodec *codec = _codec;
    uint16_t mtu = _media.outMTU;
    CodecOptions *options = _options;
    __block NSString *error = nil;
    BOOL replaced = [_streamer replaceEncoderWith:^id<A2DPEncoder> {
        NSString *message = nil;
        id<A2DPEncoder> encoder = [codec encoderForConfiguration:configuration outMTU:mtu options:options error:&message];
        error = message;
        return encoder;
    }];
    if (!replaced) {
        BBLog(@"%@: creating the encoder with the new parameters failed (%@), closing the stream and reconfiguring instead", reason, error);
        return NO;
    }
    _configuration = configuration;
    BBLog(@"%@: switching to %@ while streaming (encoder swapped only, no renegotiation)", reason, configuration.summary);
    return YES;
}

- (void)watchSampleRate {
    __weak typeof(self) weakSelf = self;
    _systemAudio.sampleRateChangedHandler = ^(double rate) { [weakSelf sampleRateChanged:rate]; };
}

- (void)sampleRateChanged:(double)rate {
    if (_stopping) return;
    if (_awaitingRate) {
        if (rate != _awaitingRate) return;
        _awaitingRate = 0;
        if (![self replaceCaptureSource]) return;
        [self configure];
        return;
    }
    if (_state < SourceStateConfigured) {
        // Headphones not configured yet: just replace the capture source and configuration will use the new rate; if
        // SET_CONFIGURATION is already in flight with a different rate, it is caught and reconfigured before streaming starts
        [self replaceCaptureSource];
        return;
    }
    if (rate == _configuration.sampleRate) return;
    // Not changed by this session (the user changed it in Audio MIDI Setup, or another program did): re-choose codec and sample rate
    BBLog(@"Virtual device sample rate changed to %g kHz, re-choosing codec and sample rate", rate / 1000);
    _pendingReconfigure = YES;
}

- (BOOL)replaceCaptureSource {
    [_systemAudio stop];
    NSString *error = nil;
    _systemAudio = _useVirtualDevice ? [[SystemAudioSource alloc] initWithDeviceUID:VirtualDeviceUID error:&error]
                                     : [[SystemAudioSource alloc] initWithError:&error];
    if (!_systemAudio) {
        [self stopWithReason:error exitCode:7];
        return NO;
    }
    [self watchSampleRate];
    BBLog(@"Capture source switched: %@", _systemAudio.formatDescription);
    return YES;
}

// Close the stream (CLOSE), re-choose the codec and run SET_CONFIGURATION → OPEN → media channel → START again; the
// signaling, HFP and AVRCP channels stay as they are
- (void)reconfigure:(NSString *)reason {
    BBLog(@"Closing the stream to reconfigure: %@", reason);
    _commandInFlight = YES;
    [_streamer pause];
    [_streamer logTotals];
    _streamer = nil;
    [_systemAudio stop];
    _media.closedHandler = nil;
    BOOL streaming = _state == SourceStateStreaming;
    _state = SourceStateSignalReady;
    _mediaRetries = 0;
    uint8_t request = (uint8_t)(_chosen.seid << 2);
    void (^close)(void) = ^{
        [self sendCommand:kSigClose payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
            [self->_media close];
            self->_media = nil;
            [self->_mediaSession closeChannel:self->_uuid psm:kAVDTPPSM];
            self->_configuration = nil;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                self->_commandInFlight = NO;
                if (self->_stopping) return;
                // The capture source is stopped: rebuild it at the current device sample rate; configure changes it if needed
                if (self->_systemAudio && ![self replaceCaptureSource]) return;
                [self configure];
            });
        }];
    };
    if (!streaming) {
        close();
        return;
    }
    // While streaming, SUSPEND before CLOSE, as Android does (system/bta/av/bta_av_aact.cc bta_av_reconfig: suspend first if
    // already streaming). A direct CLOSE while streaming once made WH-1000XM4 drop off right away (see reconsiderConfiguration)
    [self sendCommand:kSigSuspend payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
        if (self->_stopping) return;
        close();
    }];
}

#pragma mark Shutdown

- (void)stopWithReason:(NSString *)reason exitCode:(int)exitCode {
    if (_stopping) return;
    _stopping = YES;
    _exitCode = exitCode;
    BOOL normal = exitCode == 0 || exitCode == 130 || exitCode == SourceExitHandedToSystem || exitCode == SourceExitRetryNow;
    BBLog(@"%@: %@", normal ? @"Ended" : @"Failed", reason);
    if (_raceTimer) {
        dispatch_source_cancel(_raceTimer);
        _raceTimer = nil;
    }
    if (_idleTimer) {
        dispatch_source_cancel(_idleTimer);
        _idleTimer = nil;
    }
    [_streamer pause];
    [_streamer logTotals];
    [_systemAudio stop];
    if (_signal && _chosen && _state >= SourceStateConfigured) {
        _pendingReply = nil;
        uint8_t request = (uint8_t)(_chosen.seid << 2);
        // A stream that is only configured and not yet OPEN cannot be CLOSEd (the headphones return 0x31, observed 19:35:29);
        // per AVDTP, use ABORT to return the endpoint to idle
        uint8_t signal = _state == SourceStateConfigured ? kSigAbort : kSigClose;
        [self sendCommand:signal payload:&request length:1 reply:^(uint8_t messageType, const uint8_t *payload, size_t length) {
            [self teardown];
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self teardown]; });
    } else {
        [self teardown];
    }
}

- (void)teardown {
    if (_tornDown) return;
    _tornDown = YES;
    _pendingReply = nil;
    [_pairing stop];
    _pairing = nil;
    [_media close];
    [_signal close];
    [_audioGuard stop];
    if (_uuid) {
        [self resetHandsfree];
        [self resetAvrcp];
        if (_media) [_mediaSession closeChannel:_uuid psm:kAVDTPPSM];
        if (_signalSession) [_signalSession closeChannel:_uuid psm:kAVDTPPSM];
        if ((!_wasConnected || _handToSystem) && _raceSessions.count) {
            // A forced disconnect also drops all of macOS's services on this device; do it only when we initiated the
            // connection, or when handing the headphones back to macOS
            [_raceSessions[0] cancelConnection:_uuid];
            BBLog(@"Requested baseband disconnect");
        }
    }
    if (_handToSystem && _uuid && _raceSessions.count) {
        // Hand back to macOS: after disconnecting, we initiate one ordinary connection (no channel grabbing) and bluetoothd
        // connects A2DP/HFP/AVRCP as usual
        [self reconnectForSystem:0];
        return;
    }
    [self finishTeardown];
}

- (void)reconnectForSystem:(int)checks {
    if (_device.isConnected && checks < 50) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self reconnectForSystem:checks + 1]; });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        BBLog(@"Asking macOS to reconnect the headphones");
        [self->_raceSessions[0] connectDevice:self->_uuid];
        // Give the connection request time to arrive; disconnecting the XPC session afterwards does not affect the system's own connection
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self finishTeardown]; });
    });
}

- (void)finishTeardown {
    int code = _exitCode;
    void (^termination)(int) = _terminationHandler;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        // Disconnect the XPC sessions only after the close/disconnect messages sent above have arrived
        for (ClassicSession *session in self->_raceSessions) [session invalidate];
        [self->_mediaSession invalidate];
        [self->_handsfreeSession invalidate];
        [self->_avrcpSession invalidate];
        if (termination) termination(code);
        else exit(code);
    });
}

@end
