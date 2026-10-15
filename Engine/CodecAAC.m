// AAC-LC (Engine/AACEncoder: system AudioToolbox encoding + our own LATM wrapping; bit definitions and sources in AACEncoder.h).
// Media packet: 12-byte RTP header (marker bit set to 1) + LATM AudioMuxElement; timestamp advances by 1024 per AU.
// Defaults to per-frame capped VBR (the headphones must support VBR), peak = min(320k or the user setting, bitrate declared by the headphones, bitrate that fits in the MTU), exactly one packet per AU;
// CBR AUs float around the average; when one exceeds the MTU it is split into several packets as in AOSP bta_av_data_path: same timestamp, only the last fragment has the marker bit set.
// Adaptive bitrate: on congestion step down through 320/256/192/128/96k (starting at the set bitrate, at most 4 tiers, BitrateAdapter), then back up; AudioToolbox bitrate changes mid-encode
// take effect from the next AU and decoding stays continuous (tools/codectest/aac_roundtrip "change bitrate while streaming"). With VBR the peak bitrate in the configuration stays the same; the actual one only gets lower.

#import "A2DPCodec.h"
#import "A2DPProtocol.h"
#import "AACEncoder.h"
#import "BBLog.h"
#import "BitrateAdapter.h"

static const uint32_t kAACSSRC = 1;
static const size_t kAACInfoOffset = 2;  // Start of the 6-byte codec information, counted from the media type byte

@interface AACPacketizer : NSObject <A2DPEncoder>
@end

@implementation AACPacketizer {
    AACEncoder *_encoder;
    size_t _maxPayload;
    int _limit;                     // Bitrate cap allowed by the media channel MTU
    BOOL _vbr;
    int _bitrate;                   // Set bitrate (not above _limit)
    uint16_t _sequence;
    uint32_t _timestamp;
    uint64_t _fragmented;
    NSUInteger _depth;
    NSArray<NSNumber *> *_ladder;   // Adaptive tier bitrates (bit/s), high to low
    BitrateAdapter *_adapter;       // Only present when adaptive
}

- (instancetype)initWithEncoder:(AACEncoder *)encoder bitrate:(int)bitrate limit:(int)limit vbr:(BOOL)vbr adaptive:(BOOL)adaptive
                         outMTU:(uint16_t)outMTU {
    if ((self = [super init])) {
        _encoder = encoder;
        _maxPayload = outMTU - kRTPHeaderBytes;
        _limit = limit;
        _vbr = vbr;
        _bitrate = bitrate;
        [self setAdaptive:adaptive];
    }
    return self;
}

- (void)setAdaptive:(BOOL)adaptive {
    if (!adaptive) {
        _adapter = nil;
        [_encoder setBitrate:_bitrate error:nil];
        return;
    }
    if (_adapter) return;
    NSMutableArray<NSNumber *> *ladder = [NSMutableArray arrayWithObject:@(_bitrate)], *kbps = [NSMutableArray arrayWithObject:@(_bitrate / 1000)];
    for (NSNumber *step in @[@256000, @192000, @128000, @96000]) {
        if (ladder.count == 4) break;
        if (step.intValue >= _bitrate) continue;
        [ladder addObject:step];
        [kbps addObject:@(step.intValue / 1000)];
    }
    _ladder = ladder;
    _adapter = [[BitrateAdapter alloc] initWithName:@"AAC" tierKbps:kbps startTier:0 key:CodecIDAAC];
    [self applyTier];
}

- (void)applyTier {
    NSString *error = nil;
    if (![_encoder setBitrate:_ladder[_adapter.tier].intValue error:&error]) BBLog(@"AAC adaptive bitrate: failed to change bitrate (%@)", error);
}

- (void)reportQueueDepth:(NSUInteger)depth {
    _depth = depth;
}

// Bitrate and adaptive switch changes are applied in place (AudioToolbox supports changing bitrate mid-encode) without rebuilding the encoder: a rebuild re-primes and breaks the sequence. A VBR/CBR change needs a new encoder
- (BOOL)applyConfiguration:(CodecConfiguration *)configuration {
    NSDictionary *p = configuration.parameters;
    if (![configuration.codec isEqualToString:CodecIDAAC] || [p[@"vbr"] boolValue] != _vbr) return NO;
    int bitrate = MIN([p[@"bitrate"] intValue], _limit);
    if (bitrate != _bitrate) {
        if (![_encoder setBitrate:bitrate error:nil]) return NO;
        _bitrate = bitrate;
        _adapter = nil;  // Rebuild the tiers from the new bitrate
    }
    [self setAdaptive:[p[@"adaptive"] boolValue]];
    return YES;
}

- (size_t)framesPerCall {
    return _encoder.framesPerCall;
}

- (uint16_t)rtpSequence { return _sequence; }
- (void)setRtpSequence:(uint16_t)sequence { _sequence = sequence; }
- (uint32_t)rtpTimestamp { return _timestamp; }
- (void)setRtpTimestamp:(uint32_t)timestamp { _timestamp = timestamp; }

- (double)bitrateKbps {
    return _encoder.bitrate / 1000.0;
}

- (NSArray<NSData *> *)encode:(const uint8_t *)pcm error:(NSString **)error {
    if ([_adapter updateWithDepth:_depth seconds:(double)kAACFrameSamples / _encoder.sampleRate]) [self applyTier];
    NSArray<NSData *> *elements = [_encoder encodePCM24:pcm error:error];
    if (!elements) return nil;
    NSMutableArray<NSData *> *packets = [NSMutableArray array];
    for (NSData *element in elements) {
        size_t offset = 0;
        do {
            size_t chunk = MIN(_maxPayload, element.length - offset);
            BOOL last = offset + chunk == element.length;
            NSMutableData *packet = [NSMutableData dataWithLength:kRTPHeaderBytes + chunk];
            uint8_t *bytes = packet.mutableBytes;
            A2DPWriteRTPHeader(bytes, _sequence++, _timestamp, kAACSSRC, last);
            memcpy(bytes + kRTPHeaderBytes, (const uint8_t *)element.bytes + offset, chunk);
            [packets addObject:packet];
            offset += chunk;
        } while (offset < element.length);
        if (packets.count > elements.count && ++_fragmented == 1) BBLog(@"AAC frame exceeds one packet (%lu bytes), sending fragmented by MTU", (unsigned long)element.length);
        _timestamp += (uint32_t)kAACFrameSamples;
    }
    return packets;
}

@end

@interface AACCodec : A2DPCodec
@end

@implementation AACCodec

+ (void)load { [A2DPCodec registerCodecClass:self]; }

- (CodecID)identifier { return CodecIDAAC; }
- (NSString *)displayName { return @"AAC"; }
- (NSString *)vendorName { return @"MPEG"; }
- (NSInteger)rank { return 50; }
- (NSArray<NSNumber *> *)badgeColors { return @[@0x338CFA, @0x40C7ED]; }
- (NSString *)credit { return @"Apple AudioToolbox"; }

- (NSData *)fullCapabilityElement {
    static const uint8_t element[] = { 0x00, 0x02, 0xC0, 0xFF, 0xFC, 0x84, 0xE2, 0x00 };
    return [NSData dataWithBytes:element length:sizeof(element)];
}

- (BOOL)matchesElement:(NSData *)element {
    const uint8_t *bytes = element.bytes;
    return element.length >= kAACInfoOffset + 6 && bytes[1] == kCodecMPEG24 && (bytes[kAACInfoOffset] & (kAACObjectMPEG2LC | kAACObjectMPEG4LC));
}

- (NSArray<NSNumber *> *)sampleRatesInCapability:(NSData *)element {
    const uint8_t *info = (const uint8_t *)element.bytes + kAACInfoOffset;
    if (!(info[2] & kAACChannels2)) return @[];
    NSMutableArray *rates = [NSMutableArray array];
    if (info[1] & kAACFreq1_44100) [rates addObject:@44100];
    if (info[2] & kAACFreq2_48000) [rates addObject:@48000];
    return rates;
}

- (CodecConfiguration *)configurationForCapability:(NSData *)element sampleRate:(double)rate options:(CodecOptions *)options {
    const uint8_t *info = (const uint8_t *)element.bytes + kAACInfoOffset;
    if (![[self sampleRatesInCapability:element] containsObject:@(rate)]) return nil;
    uint8_t object = (info[0] & kAACObjectMPEG2LC) ? kAACObjectMPEG2LC : kAACObjectMPEG4LC;
    BOOL vbr = options.aacVBR && (info[3] & kAACVBR);
    int bitrate = options.aacBitrate > 0 ? (int)options.aacBitrate : kAACDefaultBitrate;
    int declared = AACInfoBitrate(info);
    if (declared >= kAACMinBitrate) bitrate = MIN(bitrate, declared);
    bitrate = MAX(bitrate, kAACMinBitrate);
    uint8_t config[] = {
        kMediaAudio << 4, kCodecMPEG24, object,
        rate == 44100 ? kAACFreq1_44100 : 0,
        (uint8_t)((rate == 48000 ? kAACFreq2_48000 : 0) | kAACChannels2),
        (uint8_t)((vbr ? kAACVBR : 0) | ((bitrate >> 16) & kAACBitrateHighMask)), (uint8_t)(bitrate >> 8), (uint8_t)bitrate,
    };
    NSString *summary = [NSString stringWithFormat:@"AAC-LC %g kHz stereo, %@ %d kbps (%@)%@", rate / 1000, vbr ? @"VBR peak" : @"CBR",
                         bitrate / 1000, object == kAACObjectMPEG2LC ? @"MPEG-2" : @"MPEG-4", options.aacAdaptive ? @", lowered automatically on congestion" : @""];
    return [[CodecConfiguration alloc] initWithCodec:self.identifier element:[NSData dataWithBytes:config length:sizeof config] sampleRate:rate
                                       bitsPerSample:0 nominalKbps:bitrate / 1000.0 summary:summary parameters:@{ @"bitrate": @(bitrate), @"vbr": @(vbr), @"adaptive": @(options.aacAdaptive) }];
}

- (id<A2DPEncoder>)encoderForConfiguration:(CodecConfiguration *)configuration outMTU:(uint16_t)outMTU options:(CodecOptions *)options error:(NSString **)error {
    BOOL vbr = [configuration.parameters[@"vbr"] boolValue];
    int bitrate = [configuration.parameters[@"bitrate"] intValue];
    // One AU per packet: bitrate not above the cap allowed by the MTU (AOSP A2DP_ComputeMaxBitRateAac)
    int limit = AACMaxBitrateForMTU(outMTU, configuration.sampleRate);
    if (bitrate > limit) {
        BBLog(@"AAC bitrate limited by media channel MTU %u to %d kbps", outMTU, limit / 1000);
        bitrate = limit;
    }
    AACEncoder *encoder = [[AACEncoder alloc] initWithSampleRate:configuration.sampleRate bitrate:bitrate vbr:vbr error:error];
    if (!encoder) return nil;
    BBLog(@"AAC stream parameters: %@ %d kbps, 1024 samples per packet (%.2f ms)%@", vbr ? @"VBR peak" : @"CBR", encoder.bitrate / 1000,
        1024000.0 / configuration.sampleRate, vbr ? [NSString stringWithFormat:@", per-frame cap %zu bytes", encoder.maxElementBytes] : @"");
    return [[AACPacketizer alloc] initWithEncoder:encoder bitrate:bitrate limit:limit vbr:vbr adaptive:[configuration.parameters[@"adaptive"] boolValue]
                                           outMTU:outMTU];
}

@end
