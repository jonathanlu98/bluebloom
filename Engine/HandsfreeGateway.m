#import "HandsfreeGateway.h"

// AG supported features bitmap (HFP 1.8 §4.34.1 +BRSF): only bit 10, HF indicators, is declared, to receive battery level.
// Without three-way calling and codec negotiation declared, the headphones do not send AT+CHLD or AT+BAC; when both sides support HF indicators, the SLC adds an AT+BIND round after AT+CMER (§4.2.1.6)
static const int kAGFeatures = 1 << 10;
// HF indicators (Bluetooth Assigned Numbers §7.6): 1 = enhanced safety, 2 = battery level. Like macOS bluetoothd, both are supported and enabled
static NSString *const kBINDSupported = @"+BIND: (1,2)";
static NSArray<NSString *> *BINDEnabled(void) { return @[@"+BIND: 1,1", @"+BIND: 2,1"]; }
// Indicator list and current values (example format in HFP 1.8 §4.2.1.3): service available, no call, signal 5, not roaming, battery 5
static NSString *const kIndicatorList = @"+CIND: (\"service\",(0,1)),(\"call\",(0,1)),(\"callsetup\",(0-3)),(\"callheld\",(0-2)),"
                                         @"(\"signal\",(0-5)),(\"roam\",(0,1)),(\"battchg\",(0-5))";
static NSString *const kIndicatorValues = @"+CIND: 1,0,0,0,5,0,5";
// Apple accessory commands (Accessory Design Guidelines for Apple Devices, HFP section): the AG replies "+XAPL=iPhone,<features>",
// feature bit 1 = battery reporting, bit 2 = charging/dock state; the headphones then report battery with AT+IPHONEACCEV. 7 matches macOS bluetoothd's reply without Siri
static NSString *const kXAPLResponse = @"+XAPL=iPhone,7";

@implementation HandsfreeGateway {
    L2CAPSocket *_socket;
    NSMutableData *_buffer;
}

- (instancetype)initWithSocket:(L2CAPSocket *)socket {
    if ((self = [super init])) {
        _socket = socket;
        _buffer = [NSMutableData data];
        _batteryPercent = -1;
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

- (void)received:(NSData *)data {
    [_buffer appendData:data];
    // AT commands end with \r (HFP 1.8 §4.33.1, following V.250)
    for (;;) {
        const uint8_t *bytes = _buffer.bytes;
        NSUInteger end = 0;
        while (end < _buffer.length && bytes[end] != '\r') end++;
        if (end == _buffer.length) return;
        NSString *line = [[NSString alloc] initWithBytes:bytes length:end encoding:NSASCIIStringEncoding];
        [_buffer replaceBytesInRange:NSMakeRange(0, end + 1) withBytes:NULL length:0];
        line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length) [self handleCommand:line];
    }
}

- (void)reply:(NSArray<NSString *> *)lines ok:(BOOL)ok {
    // Response format <cr><lf>result<cr><lf> (HFP 1.8 §4.33.1)
    NSMutableString *text = [NSMutableString string];
    for (NSString *line in lines) [text appendFormat:@"\r\n%@\r\n", line];
    [text appendString:ok ? @"\r\nOK\r\n" : @"\r\nERROR\r\n"];
    [_socket send:[text dataUsingEncoding:NSASCIIStringEncoding]];
}

- (void)handleCommand:(NSString *)command {
    NSString *upper = command.uppercaseString;
    if ([upper hasPrefix:@"AT+BRSF="]) {
        [self log:[NSString stringWithFormat:@"HFP handshake: headphones features %@", [command substringFromIndex:8]]];
        [self reply:@[[NSString stringWithFormat:@"+BRSF: %d", kAGFeatures]] ok:YES];
    } else if ([upper isEqualToString:@"AT+CIND=?"]) {
        [self reply:@[kIndicatorList] ok:YES];
    } else if ([upper isEqualToString:@"AT+CIND?"]) {
        [self reply:@[kIndicatorValues] ok:YES];
    } else if ([upper hasPrefix:@"AT+CMER="]) {
        [self reply:@[] ok:YES];
        if (!_serviceLevelConnected) {
            _serviceLevelConnected = YES;
            [self log:@"HFP service level connection established (held by this tool, macOS can no longer connect HFP)"];
        }
    } else if ([upper hasPrefix:@"AT+XAPL="]) {
        // AT+XAPL=<vendorID>-<productID>-<version>,<features>
        [self log:[NSString stringWithFormat:@"HFP: headphones use Apple extensions (%@)", [command substringFromIndex:8]]];
        [self reply:@[kXAPLResponse] ok:YES];
    } else if ([upper isEqualToString:@"AT+BIND=?"]) {
        [self reply:@[kBINDSupported] ok:YES];
    } else if ([upper isEqualToString:@"AT+BIND?"]) {
        [self reply:BINDEnabled() ok:YES];
    } else if ([upper hasPrefix:@"AT+BIND="]) {
        [self log:[NSString stringWithFormat:@"HFP: headphones support HF indicators %@", [command substringFromIndex:8]]];
        [self reply:@[] ok:YES];
    } else if ([upper hasPrefix:@"AT+IPHONEACCEV="]) {
        // AT+IPHONEACCEV=<pair count>,<key>,<value>,…; key 1 = battery level, 0–9 maps to 10%–100% (same Apple guidelines as above)
        NSArray<NSString *> *fields = [[command substringFromIndex:15] componentsSeparatedByString:@","];
        for (NSUInteger i = 1; i + 1 < fields.count; i += 2) {
            if (fields[i].intValue == 1) [self updateBattery:(fields[i + 1].intValue + 1) * 10];
        }
        [self reply:@[] ok:YES];
    } else if ([upper hasPrefix:@"AT+BIEV="]) {
        // AT+BIEV=<indicator>,<value>; indicator 2 = battery level 0–100 (Bluetooth Assigned Numbers, HF Indicators)
        NSArray<NSString *> *fields = [[command substringFromIndex:8] componentsSeparatedByString:@","];
        if (fields.count == 2 && fields[0].intValue == 2) [self updateBattery:fields[1].intValue];
        [self reply:@[] ok:YES];
    } else if ([upper isEqualToString:@"AT+COPS?"]) {
        [self reply:@[@"+COPS: 0,0,\"\""] ok:YES];
    } else if ([upper hasPrefix:@"AT+CMEE"] || [upper hasPrefix:@"AT+CLIP"] || [upper hasPrefix:@"AT+CCWA"] || [upper hasPrefix:@"AT+NREC"] ||
               [upper hasPrefix:@"AT+VGS"] || [upper hasPrefix:@"AT+VGM"] || [upper hasPrefix:@"AT+BIA"] || [upper hasPrefix:@"AT+COPS="] ||
               [upper isEqualToString:@"AT+CLCC"] || [upper isEqualToString:@"AT+CNUM"] || [upper isEqualToString:@"AT+BTRH?"] ||
               [upper hasPrefix:@"AT+BAC="] || [upper hasPrefix:@"AT+CHLD="] || [upper hasPrefix:@"AT+APLEFM"]) {
        // A gateway with no calls only needs to acknowledge these queries/settings; there is no call list, number, or held call
        [self reply:@[] ok:YES];
    } else {
        // Call-related commands such as dialing, answering, hanging up and voice recognition are all rejected
        [self log:[NSString stringWithFormat:@"HFP: rejecting unsupported command %@", command]];
        [self reply:@[] ok:NO];
    }
}

- (void)updateBattery:(int)percent {
    percent = MAX(0, MIN(100, percent));
    if (percent == _batteryPercent) return;
    _batteryPercent = percent;
    [self log:[NSString stringWithFormat:@"Headphones battery %d%%", percent]];
    if (_batteryHandler) _batteryHandler(percent);
}

- (void)close {
    _socket.closedHandler = nil;
    [_socket close];
}

@end
