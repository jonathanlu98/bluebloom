// SBC (the sbc_a2dp wrapper in third_party/sbc; bit definitions and sources in sbc_a2dp.h). Mandatory A2DP codec, supported by almost all headphones.
// Media packet: 12-byte RTP header + 1-byte payload header (frame count in this packet) + SBC frames; timestamp advances by sample count.
// Defaults to the high quality recommended by the A2DP spec: joint stereo, 16 blocks, 8 subbands, loudness allocation, bitpool 53 (51 at 48k), about 328 kbps;
// SBC XQ: dual channel bitpool 43 (39 at 48k), about 505 kbps (values from PipeWire a2dp-codec-sbc.c). Neither exceeds the maximum bitpool declared by the headphones.
// Adaptive bitrate: the bitpool range configured on the headphones is [headphone minimum, the value above]; on congestion the bitpool is lowered frame by frame within that range (BitrateAdapter), then raised again;
// frames per packet stay the same, packets get shorter (sbc_a2dp_set_bitpool). PipeWire also lowers the bitpool (pw-sbc.c codec_reduce_bitpool)
// The AOSP encoder's filter state is global: only one encoder can exist at a time, so invalidate the old one before creating a new one.

#import "A2DPCodec.h"
#import "A2DPProtocol.h"
#import "BBLog.h"
#import "BitrateAdapter.h"
#include "sbc_a2dp.h"

static const uint32_t kSbcSSRC = 1;
static const size_t kSbcModeByte = 2;      // Counted from the media type byte: sample rate|channel mode
static const size_t kSbcBlockByte = 3;     // Blocks|subbands|allocation method
static const size_t kSbcMinPoolByte = 4;
static const size_t kSbcMaxPoolByte = 5;

@interface SBCEncoder : NSObject <A2DPEncoder>
- (void)invalidate;
@end

static __weak SBCEncoder *gCurrentEncoder;

@implementation SBCEncoder {
    sbc_a2dp *_sbc;
    sbc_a2dp_config _config;
    int _minBitpool;
    NSMutableData *_packet;
    uint16_t _sequence;
    uint32_t _timestamp;
    NSUInteger _depth;
    NSArray<NSNumber *> *_pools;  // Bitpool of each adaptive tier, high to low
    BitrateAdapter *_adapter;     // Only present when adaptive
}

- (instancetype)initWithConfig:(const sbc_a2dp_config *)config minBitpool:(int)minBitpool adaptive:(BOOL)adaptive
                        outMTU:(uint16_t)outMTU error:(NSString **)error {
    if ((self = [super init])) {
        [gCurrentEncoder invalidate];
        char message[200] = {0};
        _sbc = sbc_a2dp_open(config, outMTU - kRTPHeaderBytes, message, sizeof message);
        if (!_sbc) {
            if (error) *error = [NSString stringWithFormat:@"Failed to open SBC encoder: %s", message];
            return nil;
        }
        _config = *config;
        _minBitpool = minBitpool;
        _packet = [NSMutableData dataWithLength:outMTU];
        gCurrentEncoder = self;
        [self setAdaptive:adaptive];
    }
    return self;
}

// Tier bitpools are 100%/85%/70%/55% of the configured value, not below the minimum declared by the headphones (55% is about the spec's middle quality: joint stereo 51 → 28, middle quality 33)
- (void)setAdaptive:(BOOL)adaptive {
    if (!adaptive) {
        _adapter = nil;
        sbc_a2dp_set_bitpool(_sbc, _config.bitpool);
        return;
    }
    if (_adapter) return;
    NSMutableArray<NSNumber *> *pools = [NSMutableArray array], *kbps = [NSMutableArray array];
    for (NSNumber *fraction in @[@1.0, @0.85, @0.7, @0.55]) {
        int pool = MAX(_minBitpool, (int)lround(_config.bitpool * fraction.doubleValue));
        if (pools.count && pool >= pools.lastObject.intValue) continue;
        sbc_a2dp_config tier = _config;
        tier.bitpool = pool;
        [pools addObject:@(pool)];
        [kbps addObject:@(sbc_a2dp_frame_length(&tier) * 8.0 * tier.sample_rate / (tier.subbands * tier.block_length) / 1000)];
    }
    _pools = pools;
    _adapter = [[BitrateAdapter alloc] initWithName:@"SBC" tierKbps:kbps startTier:0 key:CodecIDSBC];
    sbc_a2dp_set_bitpool(_sbc, _pools[_adapter.tier].intValue);
}

- (void)invalidate {
    if (_sbc) sbc_a2dp_close(_sbc);
    _sbc = NULL;
}

- (void)dealloc {
    [self invalidate];
}

- (size_t)framesPerCall {
    return _sbc ? sbc_a2dp_pcm_frames_per_packet(_sbc) : 0;
}

- (double)bitrateKbps {
    return _sbc ? sbc_a2dp_bitrate_kbps(_sbc) : 0;
}

- (void)reportQueueDepth:(NSUInteger)depth {
    _depth = depth;
}

// Applies in place when only the adaptive switch changed (other parameter changes need reconfiguration)
- (BOOL)applyConfiguration:(CodecConfiguration *)configuration {
    NSDictionary *p = configuration.parameters;
    if (!_sbc || ![configuration.codec isEqualToString:CodecIDSBC] || [p[@"bitpool"] intValue] != _config.bitpool ||
        [p[@"mode"] intValue] != _config.channel_mode || [p[@"blocks"] intValue] != _config.block_length ||
        [p[@"subbands"] intValue] != _config.subbands || [p[@"allocation"] intValue] != _config.allocation) {
        return NO;
    }
    [self setAdaptive:[p[@"adaptive"] boolValue]];
    return YES;
}

- (NSArray<NSData *> *)encode:(const uint8_t *)pcm error:(NSString **)error {
    if (!_sbc) {
        if (error) *error = @"SBC encoder was taken over by a new session";
        return nil;
    }
    double seconds = (double)sbc_a2dp_pcm_frames_per_packet(_sbc) / _config.sample_rate;
    if ([_adapter updateWithDepth:_depth seconds:seconds]) sbc_a2dp_set_bitpool(_sbc, _pools[_adapter.tier].intValue);
    char message[200] = {0};
    uint8_t *bytes = _packet.mutableBytes;
    int length = sbc_a2dp_encode(_sbc, pcm, bytes + kRTPHeaderBytes, _packet.length - kRTPHeaderBytes, message, sizeof message);
    if (length < 0) {
        if (error) *error = [NSString stringWithFormat:@"SBC encoding error: %s", message];
        return nil;
    }
    A2DPWriteRTPHeader(bytes, _sequence++, _timestamp, kSbcSSRC, NO);
    _timestamp += (uint32_t)sbc_a2dp_pcm_frames_per_packet(_sbc);
    return @[[NSData dataWithBytes:bytes length:kRTPHeaderBytes + (size_t)length]];
}

@end

@interface SBCCodec : A2DPCodec
@end

@implementation SBCCodec

+ (void)load { [A2DPCodec registerCodecClass:self]; }

- (CodecID)identifier { return CodecIDSBC; }
- (NSString *)displayName { return @"SBC"; }
- (NSString *)vendorName { return @"Bluetooth SIG"; }
- (NSInteger)rank { return 60; }
- (NSArray<NSNumber *> *)badgeColors { return @[@0x8C8C8C, @0x6B6B6B]; }
- (NSString *)credit { return @"Broadcom Corporation, Android Open Source Project · Apache License 2.0"; }
- (NSURL *)creditURL { return [NSURL URLWithString:@"https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/heads/main/system/embdrv/sbc"]; }

- (NSData *)fullCapabilityElement {
    static const uint8_t element[] = { 0x00, 0x00, 0xFF, 0xFF, 2, 250 };
    return [NSData dataWithBytes:element length:sizeof(element)];
}

- (BOOL)matchesElement:(NSData *)element {
    const uint8_t *bytes = element.bytes;
    return element.length >= 2 + kSbcInfoSize && bytes[1] == kCodecSBC;
}

- (NSArray<NSNumber *> *)sampleRatesInCapability:(NSData *)element {
    const uint8_t *bytes = element.bytes;
    NSMutableArray *rates = [NSMutableArray array];
    if (bytes[kSbcModeByte] & kSbcFreq44100) [rates addObject:@44100];
    if (bytes[kSbcModeByte] & kSbcFreq48000) [rates addObject:@48000];
    return rates;
}

static uint8_t PickBit(uint8_t available, const uint8_t *preference, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (available & preference[i]) return preference[i];
    }
    return 0;
}

static int BlockCount(uint8_t bit) {
    return bit == kSbcBlocks4 ? 4 : bit == kSbcBlocks8 ? 8 : bit == kSbcBlocks12 ? 12 : 16;
}

- (CodecConfiguration *)configurationForCapability:(NSData *)element sampleRate:(double)rate options:(CodecOptions *)options {
    const uint8_t *cap = element.bytes;
    uint8_t freq = rate == 44100 ? kSbcFreq44100 : rate == 48000 ? kSbcFreq48000 : 0;
    if (!freq || !(cap[kSbcModeByte] & freq)) return nil;
    BOOL family44 = rate == 44100;
    int minPool = MAX(cap[kSbcMinPoolByte], kSbcMinBitpool);
    int maxPool = MIN(cap[kSbcMaxPoolByte], kSbcMaxBitpool);
    uint8_t mode = 0;
    int pool = 0;
    NSString *quality;
    if (options.sbcXQ && (cap[kSbcModeByte] & kSbcChannelDual)) {
        mode = kSbcChannelDual;
        pool = family44 ? kSbcBitpoolXQDual44100 : kSbcBitpoolXQDual48000;
        quality = @"XQ dual channel";
    } else {
        static const uint8_t modes[] = { kSbcChannelJoint, kSbcChannelStereo, kSbcChannelDual, kSbcChannelMono };
        mode = PickBit(cap[kSbcModeByte] & kSbcChannelMask, modes, sizeof modes);
        // Dual channel and mono bitpools are per channel: dual channel takes half of the joint stereo high-quality value, for a comparable bitrate
        pool = mode == kSbcChannelMono ? (family44 ? kSbcBitpoolHQMono44100 : kSbcBitpoolHQMono48000)
             : mode == kSbcChannelDual ? (family44 ? kSbcBitpoolHQJoint44100 : kSbcBitpoolHQJoint48000) / 2
             : (family44 ? kSbcBitpoolHQJoint44100 : kSbcBitpoolHQJoint48000);
        quality = mode == kSbcChannelJoint ? @"joint stereo" : mode == kSbcChannelStereo ? @"stereo" : mode == kSbcChannelDual ? @"dual channel" : @"mono";
    }
    if (!mode) return nil;
    pool = MAX(minPool, MIN(pool, maxPool));
    static const uint8_t blocks[] = { kSbcBlocks16, kSbcBlocks12, kSbcBlocks8, kSbcBlocks4 };
    static const uint8_t subbands[] = { kSbcSubbands8, kSbcSubbands4 };
    static const uint8_t allocations[] = { kSbcAllocationLoudness, kSbcAllocationSNR };
    uint8_t block = PickBit(cap[kSbcBlockByte] & kSbcBlocksMask, blocks, sizeof blocks);
    uint8_t subband = PickBit(cap[kSbcBlockByte] & kSbcSubbandsMask, subbands, sizeof subbands);
    uint8_t allocation = PickBit(cap[kSbcBlockByte] & kSbcAllocationMask, allocations, sizeof allocations);
    if (!block || !subband || !allocation || pool < minPool) return nil;

    sbc_a2dp_config config = {
        .sample_rate = (int)rate, .channel_mode = mode, .block_length = BlockCount(block),
        .subbands = subband == kSbcSubbands8 ? 8 : 4, .allocation = allocation, .bitpool = pool,
    };
    double kbps = sbc_a2dp_frame_length(&config) * 8.0 * rate / (config.subbands * config.block_length) / 1000;
    uint8_t bytes[] = { kMediaAudio << 4, kCodecSBC, (uint8_t)(freq | mode), (uint8_t)(block | subband | allocation), (uint8_t)minPool, (uint8_t)pool };
    NSString *summary = [NSString stringWithFormat:@"SBC %g kHz %@, bitpool %d, %d blocks %d subbands, %.0f kbps%@", rate / 1000, quality, pool,
                         config.block_length, config.subbands, kbps, options.sbcAdaptive ? @" (lowered automatically on congestion)" : @""];
    NSDictionary *parameters = @{ @"mode": @(mode), @"blocks": @(config.block_length), @"subbands": @(config.subbands),
                                  @"allocation": @(allocation), @"bitpool": @(pool), @"minBitpool": @(minPool),
                                  @"adaptive": @(options.sbcAdaptive) };
    return [[CodecConfiguration alloc] initWithCodec:self.identifier element:[NSData dataWithBytes:bytes length:sizeof bytes]
                                          sampleRate:rate bitsPerSample:16 nominalKbps:kbps summary:summary parameters:parameters];
}

- (id<A2DPEncoder>)encoderForConfiguration:(CodecConfiguration *)configuration outMTU:(uint16_t)outMTU options:(CodecOptions *)options error:(NSString **)error {
    NSDictionary *p = configuration.parameters;
    sbc_a2dp_config config = {
        .sample_rate = (int)configuration.sampleRate, .channel_mode = [p[@"mode"] intValue], .block_length = [p[@"blocks"] intValue],
        .subbands = [p[@"subbands"] intValue], .allocation = [p[@"allocation"] intValue], .bitpool = [p[@"bitpool"] intValue],
    };
    SBCEncoder *encoder = [[SBCEncoder alloc] initWithConfig:&config minBitpool:[p[@"minBitpool"] intValue] adaptive:[p[@"adaptive"] boolValue]
                                                      outMTU:outMTU error:error];
    if (encoder) BBLog(@"SBC stream parameters: %zu samples per packet (%.2f ms), %.1f kbps", encoder.framesPerCall, encoder.framesPerCall * 1000.0 / configuration.sampleRate, encoder.bitrateKbps);
    return encoder;
}

@end
