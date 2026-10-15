#import "AvrcpController.h"
#import "BBLog.h"

// AVCTP / AV/C / AVRCP constants: BlueZ profiles/audio/avctp.h, avctp.c, avrcp.c
static const uint16_t kAvctpPid = 0x110E;  // AV Remote Control service class
enum { kAvctpCommand = 0, kAvctpResponse = 1 };
enum {
    kCtypeControl = 0x0,
    kCtypeStatus = 0x1,
    kCtypeNotify = 0x3,
    kCtypeNotImplemented = 0x8,
    kCtypeAccepted = 0x9,
    kCtypeRejected = 0xA,
    kCtypeStable = 0xC,
    kCtypeChanged = 0xD,
    kCtypeInterim = 0xF,
};
static const uint8_t kSubunitPanel = 0x09 << 3;
enum { kOpVendorDependent = 0x00, kOpUnitInfo = 0x30, kOpSubunitInfo = 0x31, kOpPassThrough = 0x7C };
static const uint8_t kCompanyBluetoothSIG[3] = { 0x00, 0x19, 0x58 };
enum {
    kPduGetCapabilities = 0x10,
    kPduGetElementAttributes = 0x20,
    kPduGetPlayStatus = 0x30,
    kPduRegisterNotification = 0x31,
    kPduSetAbsoluteVolume = 0x50,
};
enum { kCapabilityCompanyID = 0x02, kCapabilityEventsSupported = 0x03 };
enum { kEventPlaybackStatusChanged = 0x01, kEventTrackChanged = 0x02, kEventVolumeChanged = 0x0D };
enum { kStatusInvalidCommand = 0x00, kStatusInvalidParameter = 0x01 };
enum { kPlayStatusPlaying = 0x01, kPlayStatusPaused = 0x02 };

typedef void (^VendorReply)(uint8_t ctype, const uint8_t *params, size_t length);

// bluetoothd hands over a SOCK_STREAM, so consecutive messages may be glued together or split: compute the length of the first one from the AV/C frame format, returning 0 to wait for more data when incomplete
static size_t AvctpMessageLength(const uint8_t *bytes, size_t available) {
    if (available < 3) return 0;
    if (bytes[0] & 0x01) return 3;  // IPID: the peer does not support this service; AVCTP header only
    if (available < 6) return 0;
    switch (bytes[5]) {
        case kOpVendorDependent:
            if (available < 13) return 0;
            return 13 + (size_t)(bytes[11] << 8 | bytes[12]);
        case kOpPassThrough:
            if (available < 8) return 0;
            return 8 + bytes[7];
        case kOpUnitInfo:
        case kOpSubunitInfo:
            return 11;
        default:
            return available;
    }
}

@implementation AvrcpController {
    L2CAPSocket *_socket;
    NSMutableData *_buffer;
    uint8_t _nextLabel;
    NSMutableDictionary<NSNumber *, VendorReply> *_pending;
    int _statusNotifyLabel;  // label the headphones used to subscribe to playback status, -1 if not subscribed
}

- (instancetype)initWithSocket:(L2CAPSocket *)socket {
    if ((self = [super init])) {
        _socket = socket;
        _buffer = [NSMutableData data];
        _pending = [NSMutableDictionary dictionary];
        _statusNotifyLabel = -1;
        __weak typeof(self) weakSelf = self;
        socket.packetHandler = ^(NSData *data) { [weakSelf received:data]; };
        socket.closedHandler = ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf && strongSelf->_closedHandler) strongSelf->_closedHandler();
        };
    }
    return self;
}

- (void)log:(NSString *)message {
    if (_logHandler) _logHandler(message);
}

#pragma mark Send and receive

- (void)received:(NSData *)data {
    [_buffer appendData:data];
    if (_buffer.length >= 6 && AvctpMessageLength(_buffer.bytes, _buffer.length) == _buffer.length && ((const uint8_t *)_buffer.bytes)[5] != kOpVendorDependent &&
        ((const uint8_t *)_buffer.bytes)[5] != kOpPassThrough && ((const uint8_t *)_buffer.bytes)[5] != kOpUnitInfo && ((const uint8_t *)_buffer.bytes)[5] != kOpSubunitInfo) {
        [self log:[NSString stringWithFormat:@"AVRCP: received message with unknown opcode %@", BBHex(_buffer.bytes, MIN(_buffer.length, (NSUInteger)16))]];
    }
    for (;;) {
        size_t length = AvctpMessageLength(_buffer.bytes, _buffer.length);
        if (length == 0 || length > _buffer.length) return;
        NSData *message = [_buffer subdataWithRange:NSMakeRange(0, length)];
        [_buffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
        [self handleMessage:message.bytes length:message.length];
    }
}

- (void)sendLabel:(uint8_t)label type:(int)type frame:(NSData *)frame {
    NSMutableData *packet = [NSMutableData dataWithCapacity:3 + frame.length];
    uint8_t header[3] = { (uint8_t)(label << 4 | type << 1), kAvctpPid >> 8, kAvctpPid & 0xFF };
    [packet appendBytes:header length:3];
    [packet appendData:frame];
    [_socket send:packet];
}

static NSData *VendorFrame(uint8_t ctype, uint8_t pdu, const uint8_t *params, size_t length) {
    NSMutableData *frame = [NSMutableData data];
    uint8_t head[] = { ctype, kSubunitPanel, kOpVendorDependent };
    [frame appendBytes:head length:sizeof(head)];
    [frame appendBytes:kCompanyBluetoothSIG length:3];
    uint8_t pduHead[] = { pdu, 0x00, (uint8_t)(length >> 8), (uint8_t)length };  // single packet
    [frame appendBytes:pduHead length:sizeof(pduHead)];
    if (length) [frame appendBytes:params length:length];
    return frame;
}

- (void)sendVendor:(uint8_t)ctype pdu:(uint8_t)pdu params:(const uint8_t *)params length:(size_t)length reply:(VendorReply)reply {
    uint8_t label = _nextLabel;
    _nextLabel = (uint8_t)((_nextLabel + 1) & 0x0F);
    if (reply) _pending[@(label)] = [reply copy];
    [self sendLabel:label type:kAvctpCommand frame:VendorFrame(ctype, pdu, params, length)];
}

- (void)respondVendor:(uint8_t)label ctype:(uint8_t)ctype pdu:(uint8_t)pdu params:(const uint8_t *)params length:(size_t)length {
    [self sendLabel:label type:kAvctpResponse frame:VendorFrame(ctype, pdu, params, length)];
}

- (void)handleMessage:(const uint8_t *)bytes length:(size_t)length {
    if (length < 6 || (bytes[0] & 0x01)) return;
    uint8_t label = bytes[0] >> 4;
    BOOL response = (bytes[0] >> 1) & 0x01;
    uint8_t ctype = bytes[3] & 0x0F;
    uint8_t opcode = bytes[5];
    if (!response) {
        // Log every command from the headphones (there are very few) to make it easy to check whether button presses arrive
        [self log:[NSString stringWithFormat:@"AVRCP: received headphones command %@", BBHex(bytes, MIN(length, (size_t)16))]];
    }
    if (response) {
        if (opcode != kOpVendorDependent || length < 13) return;
        VendorReply reply = _pending[@(label)];
        // A notification's INTERIM is followed by a CHANGED on the same label; keep the callback
        if (ctype != kCtypeInterim) [_pending removeObjectForKey:@(label)];
        if (reply) reply(ctype, bytes + 13, length - 13);
        return;
    }
    switch (opcode) {
        case kOpUnitInfo: {
            // Reply STABLE: unit type panel, company ID Bluetooth SIG
            uint8_t frame[] = { kCtypeStable, 0xFF, kOpUnitInfo, 0x07, kSubunitPanel, 0x00, 0x19, 0x58 };
            [self sendLabel:label type:kAvctpResponse frame:[NSData dataWithBytes:frame length:sizeof(frame)]];
            break;
        }
        case kOpSubunitInfo: {
            uint8_t frame[] = { kCtypeStable, 0xFF, kOpSubunitInfo, 0x07, kSubunitPanel, 0xFF, 0xFF, 0xFF };
            [self sendLabel:label type:kAvctpResponse frame:[NSData dataWithBytes:frame length:sizeof(frame)]];
            break;
        }
        case kOpPassThrough: {
            if (length < 8) return;
            NSMutableData *frame = [NSMutableData dataWithBytes:bytes + 3 length:length - 3];
            ((uint8_t *)frame.mutableBytes)[0] = kCtypeAccepted;
            [self sendLabel:label type:kAvctpResponse frame:frame];
            BOOL released = (bytes[6] & 0x80) != 0;
            if (!released && _operationHandler) _operationHandler((AvrcpOperation)(bytes[6] & 0x7F));
            break;
        }
        case kOpVendorDependent:
            if (length >= 13) [self handleVendorCommand:bytes[10] label:label params:bytes + 13 length:length - 13];
            break;
        default: {
            NSMutableData *frame = [NSMutableData dataWithBytes:bytes + 3 length:length - 3];
            ((uint8_t *)frame.mutableBytes)[0] = kCtypeNotImplemented;
            [self sendLabel:label type:kAvctpResponse frame:frame];
            break;
        }
    }
}

#pragma mark As target (TG): answer the headphones

- (uint8_t)playStatus {
    return _playing ? kPlayStatusPlaying : kPlayStatusPaused;
}

- (void)handleVendorCommand:(uint8_t)pdu label:(uint8_t)label params:(const uint8_t *)params length:(size_t)length {
    switch (pdu) {
        case kPduGetCapabilities:
            if (length >= 1 && params[0] == kCapabilityCompanyID) {
                uint8_t reply[] = { kCapabilityCompanyID, 1, 0x00, 0x19, 0x58 };
                [self respondVendor:label ctype:kCtypeStable pdu:pdu params:reply length:sizeof(reply)];
            } else if (length >= 1 && params[0] == kCapabilityEventsSupported) {
                uint8_t reply[] = { kCapabilityEventsSupported, 2, kEventPlaybackStatusChanged, kEventTrackChanged };
                [self respondVendor:label ctype:kCtypeStable pdu:pdu params:reply length:sizeof(reply)];
            } else {
                uint8_t error = kStatusInvalidParameter;
                [self respondVendor:label ctype:kCtypeRejected pdu:pdu params:&error length:1];
            }
            break;
        case kPduRegisterNotification:
            if (length >= 1 && params[0] == kEventPlaybackStatusChanged) {
                _statusNotifyLabel = label;
                uint8_t reply[] = { kEventPlaybackStatusChanged, [self playStatus] };
                [self respondVendor:label ctype:kCtypeInterim pdu:pdu params:reply length:sizeof(reply)];
            } else if (length >= 1 && params[0] == kEventTrackChanged) {
                // Browsing not supported: an all-zero track identifier means "current track selected" (AVRCP 1.4 and later)
                uint8_t reply[9] = { kEventTrackChanged };
                [self respondVendor:label ctype:kCtypeInterim pdu:pdu params:reply length:sizeof(reply)];
            } else {
                uint8_t error = kStatusInvalidParameter;
                [self respondVendor:label ctype:kCtypeRejected pdu:pdu params:&error length:1];
            }
            break;
        case kPduGetPlayStatus: {
            // Track length and position unknown (0xFFFFFFFF); report playback status only
            uint8_t reply[9] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, [self playStatus] };
            [self respondVendor:label ctype:kCtypeStable pdu:pdu params:reply length:sizeof(reply)];
            break;
        }
        case kPduGetElementAttributes: {
            uint8_t none = 0;  // no track information provided
            [self respondVendor:label ctype:kCtypeStable pdu:pdu params:&none length:1];
            break;
        }
        default: {
            uint8_t error = kStatusInvalidCommand;
            [self respondVendor:label ctype:kCtypeRejected pdu:pdu params:&error length:1];
            break;
        }
    }
}

- (void)setPlaying:(BOOL)playing {
    if (_playing == playing) return;
    _playing = playing;
    if (_statusNotifyLabel < 0) return;
    // Each subscription gets only one CHANGED; the headphones need to subscribe again
    uint8_t reply[] = { kEventPlaybackStatusChanged, [self playStatus] };
    [self respondVendor:(uint8_t)_statusNotifyLabel ctype:kCtypeChanged pdu:kPduRegisterNotification params:reply length:sizeof(reply)];
    _statusNotifyLabel = -1;
}

#pragma mark As controller (CT): absolute volume

- (void)start {
    uint8_t capability = kCapabilityEventsSupported;
    [self sendVendor:kCtypeStatus pdu:kPduGetCapabilities params:&capability length:1 reply:^(uint8_t ctype, const uint8_t *params, size_t length) {
        if (ctype != kCtypeStable || length < 2 || params[0] != kCapabilityEventsSupported) {
            [self log:[NSString stringWithFormat:@"AVRCP: querying headphones capabilities failed (response 0x%X)", ctype]];
            return;
        }
        for (size_t i = 0; i < params[1] && 2 + i < length; i++) {
            if (params[2 + i] == kEventVolumeChanged) self->_absoluteVolumeSupported = YES;
        }
        [self log:self->_absoluteVolumeSupported ? @"AVRCP: headphones support absolute volume, starting volume sync" : @"AVRCP: headphones do not support absolute volume"];
        if (self->_absoluteVolumeSupported) [self registerVolume];
    }];
}

- (void)registerVolume {
    uint8_t params[5] = { kEventVolumeChanged };  // the last 4 bytes are the playback interval, unused for the volume event
    [self sendVendor:kCtypeNotify pdu:kPduRegisterNotification params:params length:sizeof(params) reply:^(uint8_t ctype, const uint8_t *reply, size_t length) {
        if ((ctype == kCtypeInterim || ctype == kCtypeChanged) && length >= 2 && reply[0] == kEventVolumeChanged) {
            if (self->_volumeHandler) self->_volumeHandler(reply[1] & 0x7F);
            if (ctype == kCtypeChanged) [self registerVolume];
        } else if (ctype != kCtypeInterim) {
            [self log:[NSString stringWithFormat:@"AVRCP: subscribing to volume changes failed (response 0x%X)", ctype]];
        }
    }];
}

- (void)setAbsoluteVolume:(int)volume {
    if (!_absoluteVolumeSupported) return;
    uint8_t value = (uint8_t)MAX(0, MIN(127, volume));
    [self sendVendor:kCtypeControl pdu:kPduSetAbsoluteVolume params:&value length:1 reply:^(uint8_t ctype, const uint8_t *params, size_t length) {
        if (ctype != kCtypeAccepted) [self log:[NSString stringWithFormat:@"AVRCP: set volume rejected (response 0x%X)", ctype]];
    }];
}

- (void)close {
    _socket.closedHandler = nil;
    [_socket close];
}

@end
