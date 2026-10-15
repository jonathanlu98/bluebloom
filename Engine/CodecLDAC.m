// LDAC (the ldac_a2dp wrapper in third_party/libldac; bit definitions and sources in ldac_a2dp.h).
// Media packet: 12-byte RTP header + 1-byte payload header (frame count in this packet) + LDAC frames; timestamp advances by sample count (Android a2dp_vendor_ldac_encoder.cc).
// Requires media channel outgoing MTU ≥ 679; the library always packs about 661 bytes of frame data per packet, so a larger MTU goes unused.

#import "A2DPCodec.h"
#import "A2DPProtocol.h"
#import "BBLog.h"
#include <os/lock.h>
#include "ldac_a2dp.h"

static const size_t kLdacFreqByte = 2 + kLdacInfoFreqIndex;      // Index counted from the media type byte
static const size_t kLdacChannelByte = 2 + kLdacInfoChannelIndex;
static const uint32_t kLdacSSRC = 1;

// A bitrate tier's identifier is the quality parameter of ldac_a2dp_open: -1 adaptive (ABR, switches among 990/660/492/396/330, starting at 660),
// 0 high, 1 standard, 2 mobile
enum { kLdacQualityAdaptive = -1, kLdacQualityHigh = 0, kLdacQualityStandard = 1, kLdacQualityMobile = 2 };

static const struct { double rate; uint8_t bit; } kLdacRates[] = {
    { 44100, kLdacFreq44100 }, { 48000, kLdacFreq48000 }, { 88200, kLdacFreq88200 }, { 96000, kLdacFreq96000 },
};

// ABR step-up backoff state (ldac_a2dp.h ldac_abr_guard) is kept across encoders: when the stream restarts after idle suspend or is closed and reconfigured, it reuses the previous stream's conclusion,
// so each new stream does not start at 990 and drop two tiers right away. Only one pair of headphones streams at a time, so one copy is enough; the block time is reduced by the elapsed wall-clock interval
static ldac_abr_guard gAbrGuard = { -1, 0, 0, -1 };
static CFAbsoluteTime gAbrGuardSavedAt;
static os_unfair_lock gAbrGuardLock = OS_UNFAIR_LOCK_INIT;

@interface LDACEncoder : NSObject <A2DPEncoder>
@end

@implementation LDACEncoder {
    ldac_a2dp *_ldac;
    NSMutableData *_payload;
    uint16_t _sequence;
    uint32_t _timestamp;
    int _lastKbps;
    BOOL _adaptive;
}

- (instancetype)initWithRate:(double)rate quality:(NSInteger)quality outMTU:(uint16_t)outMTU error:(NSString **)error {
    if ((self = [super init])) {
        char message[200] = {0};
        _ldac = ldac_a2dp_open((int)rate, kLdacChannelStereo, (int)quality, outMTU - kRTPHeaderBytes, message, sizeof message);
        if (!_ldac) {
            if (error) *error = [NSString stringWithFormat:@"Failed to open LDAC encoder: %s", message];
            return nil;
        }
        _payload = [NSMutableData dataWithLength:outMTU];
        _adaptive = quality == kLdacQualityAdaptive;
        if (_adaptive) {
            os_unfair_lock_lock(&gAbrGuardLock);
            ldac_abr_guard guard = gAbrGuard;
            guard.remaining -= CFAbsoluteTimeGetCurrent() - gAbrGuardSavedAt;
            os_unfair_lock_unlock(&gAbrGuardLock);
            ldac_a2dp_set_abr_guard(_ldac, &guard);
            if (guard.ceiling >= 0 && guard.remaining > 0) {
                BBLog(@"LDAC adaptive bitrate: reusing the previous stream's conclusion, starting at %d kbps, trying a higher tier again in %.0f s", ldac_a2dp_bitrate_kbps(_ldac),
                    guard.remaining);
            }
        }
        _lastKbps = ldac_a2dp_bitrate_kbps(_ldac);
    }
    return self;
}

- (void)dealloc {
    if (_ldac && _adaptive) {
        os_unfair_lock_lock(&gAbrGuardLock);
        ldac_a2dp_get_abr_guard(_ldac, &gAbrGuard);
        gAbrGuardSavedAt = CFAbsoluteTimeGetCurrent();
        os_unfair_lock_unlock(&gAbrGuardLock);
    }
    if (_ldac) ldac_a2dp_close(_ldac);
}

- (size_t)framesPerCall {
    return ldac_a2dp_frames_per_call(_ldac);
}

- (double)bitrateKbps {
    return ldac_a2dp_bitrate_kbps(_ldac);
}

- (uint16_t)rtpSequence { return _sequence; }
- (void)setRtpSequence:(uint16_t)sequence { _sequence = sequence; }
- (uint32_t)rtpTimestamp { return _timestamp; }
- (void)setRtpTimestamp:(uint32_t)timestamp { _timestamp = timestamp; }

- (void)reportQueueDepth:(NSUInteger)depth {
    ldac_a2dp_set_queue_depth(_ldac, (int)MIN(depth, (NSUInteger)255));
}

- (NSArray<NSData *> *)encode:(const uint8_t *)pcm error:(NSString **)error {
    char message[200] = {0};
    size_t packetFrames = 0;
    uint8_t *payload = _payload.mutableBytes;
    int length = ldac_a2dp_encode(_ldac, pcm, payload + kRTPHeaderBytes, _payload.length - kRTPHeaderBytes, &packetFrames, message, sizeof message);
    if (length < 0) {
        if (error) *error = [NSString stringWithFormat:@"LDAC encoding error: %s", message];
        return nil;
    }
    int kbps = ldac_a2dp_bitrate_kbps(_ldac);
    if (kbps != _lastKbps) {
        BBLog(@"LDAC adaptive bitrate: %d → %d kbps", _lastKbps, kbps);
        _lastKbps = kbps;
    }
    int blockedKbps = 0;
    double blockedSeconds = 0;
    if (ldac_a2dp_take_abr_block(_ldac, &blockedKbps, &blockedSeconds)) {
        BBLog(@"LDAC adaptive bitrate: link cannot sustain %d kbps, not retrying this tier for %.0f s", blockedKbps, blockedSeconds);
    }
    if (length == 0) return @[];
    A2DPWriteRTPHeader(payload, _sequence++, _timestamp, kLdacSSRC, NO);
    _timestamp += (uint32_t)packetFrames;
    return @[[NSData dataWithBytes:payload length:kRTPHeaderBytes + (size_t)length]];
}

@end

@interface LDACCodec : A2DPCodec
@end

@implementation LDACCodec

+ (void)load { [A2DPCodec registerCodecClass:self]; }

- (CodecID)identifier { return CodecIDLDAC; }
- (NSString *)displayName { return @"LDAC"; }
- (NSString *)vendorName { return @"Sony"; }
- (NSInteger)rank { return 10; }
- (BOOL)isPremium { return YES; }
- (NSArray<NSNumber *> *)badgeColors { return @[@0x9E52FA, @0xED54B3]; }
- (NSString *)credit { return @"libldac — Sony Corporation · Apache License 2.0"; }
- (NSString *)trademark { return @"LDAC is a trademark of Sony Corporation."; }
- (NSURL *)creditURL { return [NSURL URLWithString:@"https://android.googlesource.com/platform/external/libldac"]; }

- (NSArray<CodecPreset *> *)presets {
    return @[
        [CodecPreset adaptivePresetWithID:kLdacQualityAdaptive kbps:990 kbps44:909 minimumKbps:330],
        [CodecPreset presetWithID:kLdacQualityHigh kbps:990 kbps44:909],
        [CodecPreset presetWithID:kLdacQualityStandard kbps:660 kbps44:606],
        [CodecPreset presetWithID:kLdacQualityMobile kbps:330 kbps44:303],
    ];
}

- (NSInteger)defaultPresetID { return kLdacQualityAdaptive; }

- (NSData *)fullCapabilityElement {
    static const uint8_t element[] = { 0x00, 0xFF, 0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00, 0x3C, 0x07 };
    return [NSData dataWithBytes:element length:sizeof(element)];
}

- (BOOL)matchesElement:(NSData *)element {
    return A2DPIsVendorElement(element, kLdacVendorID, kLdacCodecID, 2 + kLdacInfoSize);
}

- (NSArray<NSNumber *> *)sampleRatesInCapability:(NSData *)element {
    const uint8_t *bytes = element.bytes;
    if (!(bytes[kLdacChannelByte] & kLdacChannelStereo)) return @[];
    NSMutableArray *rates = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(kLdacRates) / sizeof(kLdacRates[0]); i++) {
        if (bytes[kLdacFreqByte] & kLdacRates[i].bit) [rates addObject:@(kLdacRates[i].rate)];
    }
    return rates;
}

- (CodecConfiguration *)configurationForCapability:(NSData *)element sampleRate:(double)rate options:(CodecOptions *)options {
    uint8_t bit = 0;
    for (size_t i = 0; i < sizeof(kLdacRates) / sizeof(kLdacRates[0]); i++) {
        if (kLdacRates[i].rate == rate) bit = kLdacRates[i].bit;
    }
    const uint8_t *capability = element.bytes;
    if (!bit || !(capability[kLdacFreqByte] & bit) || !(capability[kLdacChannelByte] & kLdacChannelStereo)) return nil;
    NSMutableData *config = [NSMutableData dataWithBytes:element.bytes length:2 + kLdacInfoSize];
    uint8_t *bytes = config.mutableBytes;
    bytes[0] = kMediaAudio << 4;
    bytes[kLdacFreqByte] = bit;
    bytes[kLdacChannelByte] = kLdacChannelStereo;
    CodecPreset *preset = [self presetForOptions:options];
    double kbps = [preset kbpsAtSampleRate:rate];
    NSString *quality = preset.adaptive ? @"adaptive bitrate" : [NSString stringWithFormat:@"%.0f kbps", kbps];
    NSString *summary = [NSString stringWithFormat:@"LDAC %g kHz/24-bit stereo, %@", rate / 1000, quality];
    return [[CodecConfiguration alloc] initWithCodec:self.identifier element:config sampleRate:rate bitsPerSample:24
                                         nominalKbps:kbps summary:summary parameters:@{ @"quality": @(preset.identifier) }];
}

- (id<A2DPEncoder>)encoderForConfiguration:(CodecConfiguration *)configuration outMTU:(uint16_t)outMTU options:(CodecOptions *)options error:(NSString **)error {
    if (outMTU < kLdacMinL2CAPMTU) {
        if (error) *error = [NSString stringWithFormat:@"Media channel MTU %u is below the %d LDAC requires", outMTU, kLdacMinL2CAPMTU];
        return nil;
    }
    NSInteger quality = [configuration.parameters[@"quality"] integerValue];
    return [[LDACEncoder alloc] initWithRate:configuration.sampleRate quality:quality outMTU:outMTU error:error];
}

@end
